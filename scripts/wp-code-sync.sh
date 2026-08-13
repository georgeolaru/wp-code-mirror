#!/usr/bin/env bash

set -euo pipefail

DEFAULT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -n "${PATH:-}" ]]; then
  PATH="${PATH}:${DEFAULT_PATH}"
else
  PATH="${DEFAULT_PATH}"
fi
export PATH

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

detect_default_storage_root() {
  if [[ "${ROOT_DIR}" == */wp-content/plugins/* ]]; then
    printf '%s/wp-content/uploads/wp-code-mirror\n' "${ROOT_DIR%/wp-content/plugins/*}"
    return
  fi

  printf '%s\n' "${ROOT_DIR}"
}

DEFAULT_STORAGE_ROOT="$(detect_default_storage_root)"
DEFAULT_CONFIG_PATH="${DEFAULT_STORAGE_ROOT}/config/wp-code-mirror.config.json"
DEFAULT_LOCK_DIR="${DEFAULT_STORAGE_ROOT}/tmp/locks"
DEFAULT_INTERVAL="15"
DEFAULT_MAX_INTERVAL="300"
DEFAULT_DEBOUNCE="1"
DEFAULT_LOG_MAX_BYTES="1048576"
CHANGE_PREFIX="__WPCM_CHANGE__"
MAX_CHANGE_SAMPLES=100
MAX_DIAGNOSTIC_SAMPLES=10

LOG_FILE=""
ERROR_LOG_FILE=""
LOG_MAX_BYTES="${DEFAULT_LOG_MAX_BYTES}"
LOCK_PATH=""
LOCK_OWNER_PID=""
WATCH_ACTIVE=0
STOP_LOGGED=0

RSYNC_EXIT_CODE=0
RSYNC_CHANGES_JSON='[]'
RSYNC_CHANGE_COUNT=0
RSYNC_WARNINGS_JSON='[]'
RSYNC_WARNING_COUNT=0
RSYNC_ERRORS_JSON='[]'
RSYNC_ERROR_COUNT=0
RSYNC_EXCLUDES_JSON='[]'

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-sync.sh status [--config <path>] [--target <label>] [--json] [--status-file <path>] [--lock-dir <path>]
  bash scripts/wp-code-sync.sh sync   [--config <path>] [--target <label>] [--json] [--status-file <path>] [--lock-dir <path>]
  bash scripts/wp-code-sync.sh watch  --target <label> [--config <path>] [--interval <seconds>] [--max-interval <seconds>] [--debounce <seconds>] [--status-file <path>] [--lock-dir <path>] [--log-file <path>] [--error-log-file <path>] [--log-max-bytes <bytes>]

Watch defaults: interval 15s, debounce 1s, exponential idle backoff up to 300s.
EOF
}

iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

trim_trailing_slash() {
  local path="$1"
  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "${path}"
}

sanitize_label() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

file_size() {
  local path="$1"
  [[ -f "${path}" ]] || { printf '0\n'; return; }
  wc -c <"${path}" | tr -d ' '
}

rotate_log_if_needed() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  [[ -f "${path}" ]] || return 0

  local size
  size="$(file_size "${path}")"
  if [[ "${size}" -ge "${LOG_MAX_BYTES}" ]]; then
    mv -f "${path}" "${path}.1"
  fi
}

append_log() {
  local path="$1"
  local level="$2"
  local event="$3"
  shift 3

  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  rotate_log_if_needed "${path}"
  printf '%s %s %s%s\n' "$(iso_timestamp)" "${level}" "${event}" "${*:+ $*}" >>"${path}"
}

log_info() {
  append_log "${LOG_FILE}" "INFO" "$@"
}

log_warning() {
  append_log "${LOG_FILE}" "WARN" "$@"
}

log_error() {
  append_log "${ERROR_LOG_FILE}" "ERROR" "$@"
}

fail() {
  log_error "FATAL" "$*"
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fail "missing required tool: ${name}"
}

is_nonnegative_number() {
  awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }'
}

is_positive_number() {
  awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'
}

next_backoff() {
  local current="$1"
  local maximum="$2"
  awk -v current="${current}" -v maximum="${maximum}" 'BEGIN { candidate = current * 2; if (candidate > maximum) candidate = maximum; printf "%.3f\n", candidate }'
}

validate_config() {
  local config_path="$1"

  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  jq -e '
    (.source_site | type == "string" and length > 1) and
    (.targets | type == "array") and
    all(.targets[];
      (.label | type == "string" and length > 0) and
      (.site_path | type == "string" and length > 1) and
      ((if has("active") then .active else true end) | type == "boolean") and
      ((.themes // []) | type == "array") and
      ((.plugins // []) | type == "array") and
      ((.mu_plugins // []) | type == "array")
    )
  ' "${config_path}" >/dev/null || fail "invalid config structure in ${config_path}"
}

load_global_config() {
  local config_path="$1"

  SOURCE_SITE="$(jq -r '.source_site' "${config_path}")"
  SOURCE_SITE="$(trim_trailing_slash "${SOURCE_SITE}")"
  [[ -d "${SOURCE_SITE}/wp-content/themes" ]] || fail "source themes directory missing: ${SOURCE_SITE}/wp-content/themes"
  [[ -d "${SOURCE_SITE}/wp-content/plugins" ]] || fail "source plugins directory missing: ${SOURCE_SITE}/wp-content/plugins"

  RSYNC_EXCLUDES=()
  RSYNC_EXCLUDES_JSON="$(jq -c '.rsync_excludes // []' "${config_path}")"
  while IFS= read -r exclude_pattern; do
    [[ -n "${exclude_pattern}" ]] || continue
    RSYNC_EXCLUDES+=("--exclude=${exclude_pattern}")
  done < <(jq -r '.rsync_excludes[]? // empty' "${config_path}")
}

iter_targets() {
  local config_path="$1"
  local target_label="${2:-}"

  if [[ -n "${target_label}" ]]; then
    jq -c --arg label "${target_label}" '.targets[] | select(.label == $label)' "${config_path}"
  else
    jq -c '.targets[]' "${config_path}"
  fi
}

iter_target_items() {
  local target_json="$1"
  jq -r '
    ((.themes // [])[] | "themes\t" + .),
    ((.plugins // [])[] | "plugins\t" + .),
    ((.mu_plugins // [])[] | "mu-plugins\t" + .)
  ' <<<"${target_json}"
}

target_site_is_present() {
  local site_path="$1"
  [[ -d "${site_path}/wp-content/themes" && -d "${site_path}/wp-content/plugins" ]]
}

write_status_file() {
  local status_path="$1"
  local json_payload="$2"
  [[ -n "${status_path}" ]] || return 0

  local status_dir temporary
  status_dir="$(dirname "${status_path}")"
  mkdir -p "${status_dir}"
  temporary="$(mktemp "${status_path}.tmp.XXXXXX")"
  if ! printf '%s\n' "${json_payload}" | jq -c '.' >"${temporary}"; then
    rm -f "${temporary}"
    fail "could not write valid status JSON: ${status_path}"
  fi
  mv -f "${temporary}" "${status_path}"
}

release_target_lock() {
  [[ -n "${LOCK_PATH}" && -d "${LOCK_PATH}" ]] || return 0

  local owner=""
  if [[ -f "${LOCK_PATH}/owner" ]]; then
    owner="$(sed -n '1p' "${LOCK_PATH}/owner" 2>/dev/null || true)"
  fi

  if [[ "${owner}" == "${LOCK_OWNER_PID}" ]]; then
    rm -f "${LOCK_PATH}/owner"
    rmdir "${LOCK_PATH}" 2>/dev/null || true
  fi

  LOCK_PATH=""
  LOCK_OWNER_PID=""
}

acquire_target_lock() {
  local target_label="$1"
  local lock_root="$2"
  local safe_label owner

  safe_label="$(sanitize_label "${target_label}")"
  [[ -n "${safe_label}" ]] || fail "target label cannot produce an empty lock key"
  mkdir -p "${lock_root}"
  LOCK_PATH="${lock_root}/${safe_label}.lock"
  LOCK_OWNER_PID="$$"

  if mkdir "${LOCK_PATH}" 2>/dev/null; then
    printf '%s\n' "${LOCK_OWNER_PID}" >"${LOCK_PATH}/owner"
    return 0
  fi

  owner=""
  if [[ -f "${LOCK_PATH}/owner" ]]; then
    owner="$(sed -n '1p' "${LOCK_PATH}/owner" 2>/dev/null || true)"
  fi

  if [[ "${owner}" =~ ^[0-9]+$ ]] && kill -0 "${owner}" 2>/dev/null; then
    printf 'Target cycle already running for %s (pid %s).\n' "${target_label}" "${owner}" >&2
    LOCK_PATH=""
    LOCK_OWNER_PID=""
    return 75
  fi

  rm -f "${LOCK_PATH}/owner"
  if ! rmdir "${LOCK_PATH}" 2>/dev/null; then
    printf 'Could not recover target lock for %s.\n' "${target_label}" >&2
    LOCK_PATH=""
    LOCK_OWNER_PID=""
    return 75
  fi

  log_warning "LOCK_RECOVERED" "target=${target_label} previous_pid=${owner:-unknown}"
  if ! mkdir "${LOCK_PATH}" 2>/dev/null; then
    printf 'Target cycle already running for %s.\n' "${target_label}" >&2
    LOCK_PATH=""
    LOCK_OWNER_PID=""
    return 75
  fi

  printf '%s\n' "${LOCK_OWNER_PID}" >"${LOCK_PATH}/owner"
}

json_array_from_file() {
  local path="$1"
  local limit="$2"
  awk -v limit="${limit}" 'NF && count < limit { print; count++ }' "${path}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

json_unique_array_from_file() {
  local path="$1"
  local limit="$2"
  awk -v limit="${limit}" 'NF && !seen[$0]++ && count < limit { print; count++ }' "${path}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

count_nonempty_lines() {
  local path="$1"
  awk 'NF { count++ } END { print count + 0 }' "${path}"
}

run_rsync_operation() {
  local operation="$1"
  local source_path="$2"
  local target_path="$3"
  local raw_file changes_file diagnostics_file warnings_file errors_file
  local exit_code execute_directory=""

  raw_file="$(mktemp)"
  changes_file="$(mktemp)"
  diagnostics_file="$(mktemp)"
  warnings_file="$(mktemp)"
  errors_file="$(mktemp)"

  exit_code=0
  local -a command
  command=(rsync -a)
  if [[ -d "${source_path}" ]]; then
    command+=(--delete)
  else
    command+=(--relative)
  fi
  if [[ "${operation}" == "analyze" ]]; then
    command+=(--dry-run --itemize-changes "--out-format=${CHANGE_PREFIX}%i|%n%L")
  else
    command+=(--itemize-changes "--out-format=${CHANGE_PREFIX}%i|%n%L")
  fi
  command+=(${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"})

  if [[ -d "${source_path}" ]]; then
    if [[ "${operation}" != "analyze" ]]; then
      mkdir -p "${target_path}"
    fi
    command+=("${source_path}/" "${target_path}/")
  else
    local source_root target_root relative_source
    source_root="${source_path%%/wp-content/*}/wp-content"
    target_root="${target_path%%/wp-content/*}/wp-content"
    relative_source="./${source_path#"${source_root}/"}"
    execute_directory="${source_root}"
    command+=("${relative_source}" "${target_root}/")
  fi

  if [[ -n "${execute_directory}" ]]; then
    (cd "${execute_directory}" && "${command[@]}") >"${raw_file}" 2>&1
    exit_code=$?
  elif "${command[@]}" >"${raw_file}" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  awk \
    -v prefix="${CHANGE_PREFIX}" \
    -v changes_file="${changes_file}" \
    -v diagnostics_file="${diagnostics_file}" '
      !NF { next }
      index($0, prefix) == 1 {
        print substr($0, length(prefix) + 1) >> changes_file
        next
      }
      { print >> diagnostics_file }
    ' "${raw_file}"

  if [[ "${exit_code}" -eq 0 && ! -s "${raw_file}" && ! -s "${changes_file}" ]]; then
    RSYNC_EXIT_CODE=0
    RSYNC_CHANGE_COUNT=0
    RSYNC_WARNING_COUNT=0
    RSYNC_ERROR_COUNT=0
    RSYNC_CHANGES_JSON='[]'
    RSYNC_WARNINGS_JSON='[]'
    RSYNC_ERRORS_JSON='[]'
    rm -f "${raw_file}" "${changes_file}" "${diagnostics_file}" "${warnings_file}" "${errors_file}"
    return
  fi

  if [[ "${exit_code}" -eq 0 || "${exit_code}" -eq 24 ]]; then
    cp "${diagnostics_file}" "${warnings_file}"
  else
    cp "${diagnostics_file}" "${errors_file}"
    if [[ ! -s "${errors_file}" ]]; then
      printf 'rsync exited with code %s\n' "${exit_code}" >"${errors_file}"
    fi
  fi

  RSYNC_EXIT_CODE="${exit_code}"
  RSYNC_CHANGE_COUNT="$(count_nonempty_lines "${changes_file}")"
  RSYNC_WARNING_COUNT="$(count_nonempty_lines "${warnings_file}")"
  RSYNC_ERROR_COUNT="$(count_nonempty_lines "${errors_file}")"
  RSYNC_CHANGES_JSON="$(json_array_from_file "${changes_file}" "${MAX_CHANGE_SAMPLES}")"
  RSYNC_WARNINGS_JSON="$(json_unique_array_from_file "${warnings_file}" "${MAX_DIAGNOSTIC_SAMPLES}")"
  RSYNC_ERRORS_JSON="$(json_unique_array_from_file "${errors_file}" "${MAX_DIAGNOSTIC_SAMPLES}")"

  rm -f "${raw_file}" "${changes_file}" "${diagnostics_file}" "${warnings_file}" "${errors_file}"
}

analyze_component() {
  local kind="$1"
  local slug="$2"
  local source_path="$3"
  local target_path="$4"
  local state pending sync_required retry

  if [[ ! -e "${source_path}" ]]; then
    jq -cn \
      --arg kind "${kind}" \
      --arg slug "${slug}" \
      --arg source_path "${source_path}" \
      --arg target_path "${target_path}" \
      --arg error "source item missing: ${source_path}" \
      '{kind:$kind,slug:$slug,source_path:$source_path,target_path:$target_path,state:"ERROR",pending:false,sync_required:false,retry:false,synced:false,changes:[],change_count:0,warnings:[],warning_count:0,errors:[$error],error_count:1,rsync_exit_code:null}'
    return
  fi

  run_rsync_operation "analyze" "${source_path}" "${target_path}"

  state="CLEAN"
  pending=false
  sync_required=false
  retry=false
  if [[ "${RSYNC_ERROR_COUNT}" -gt 0 ]]; then
    state="ERROR"
  elif [[ "${RSYNC_CHANGE_COUNT}" -gt 0 ]]; then
    state="PENDING"
    pending=true
    sync_required=true
  elif [[ "${RSYNC_EXIT_CODE}" -eq 24 ]]; then
    state="PENDING"
    pending=true
    retry=true
  fi

  jq -cn \
    --arg kind "${kind}" \
    --arg slug "${slug}" \
    --arg source_path "${source_path}" \
    --arg target_path "${target_path}" \
    --arg state "${state}" \
    --argjson pending "${pending}" \
    --argjson sync_required "${sync_required}" \
    --argjson retry "${retry}" \
    --argjson changes "${RSYNC_CHANGES_JSON}" \
    --argjson change_count "${RSYNC_CHANGE_COUNT}" \
    --argjson warnings "${RSYNC_WARNINGS_JSON}" \
    --argjson warning_count "${RSYNC_WARNING_COUNT}" \
    --argjson errors "${RSYNC_ERRORS_JSON}" \
    --argjson error_count "${RSYNC_ERROR_COUNT}" \
    --argjson exit_code "${RSYNC_EXIT_CODE}" \
    '{kind:$kind,slug:$slug,source_path:$source_path,target_path:$target_path,state:$state,pending:$pending,sync_required:$sync_required,retry:$retry,synced:false,changes:$changes,change_count:$change_count,warnings:$warnings,warning_count:$warning_count,errors:$errors,error_count:$error_count,rsync_exit_code:$exit_code}'
}

aggregate_items_state() {
  jq -r '
    if any(.[]; .state == "ERROR") then "ERROR"
    elif any(.[]; .state == "PENDING") then "PENDING"
    else "CLEAN"
    end
  '
}

analyze_target() {
  local target_json="$1"
  local label site_path active kind slug source_path target_path items_file state

  label="$(jq -r '.label' <<<"${target_json}")"
  site_path="$(jq -r '.site_path' <<<"${target_json}")"
  site_path="$(trim_trailing_slash "${site_path}")"
  active="$(jq -r 'if has("active") then .active else true end' <<<"${target_json}")"

  if [[ "${active}" != "true" ]]; then
    jq -cn --arg label "${label}" --arg site_path "${site_path}" \
      '{label:$label,site_path:$site_path,active:false,state:"MISSING",reason:"INACTIVE",items:[],warning_count:0,error_count:0}'
    return
  fi

  if ! target_site_is_present "${site_path}"; then
    jq -cn --arg label "${label}" --arg site_path "${site_path}" \
      '{label:$label,site_path:$site_path,active:true,state:"MISSING",reason:"TARGET_MISSING",items:[],warning_count:0,error_count:0}'
    return
  fi

  if [[ "${site_path}" == "${SOURCE_SITE}" ]]; then
    jq -cn --arg label "${label}" --arg site_path "${site_path}" \
      '{label:$label,site_path:$site_path,active:true,state:"ERROR",reason:"SOURCE_EQUALS_TARGET",items:[],warning_count:0,error_count:1,errors:["source and target paths must differ"]}'
    return
  fi

  items_file="$(mktemp)"
  while IFS=$'\t' read -r kind slug; do
    [[ -n "${kind}" ]] || continue
    source_path="${SOURCE_SITE}/wp-content/${kind}/${slug}"
    target_path="${site_path}/wp-content/${kind}/${slug}"
    analyze_component "${kind}" "${slug}" "${source_path}" "${target_path}" >>"${items_file}"
  done < <(iter_target_items "${target_json}")

  state="$(jq -s 'if any(.[]; .state == "ERROR") then "ERROR" elif any(.[]; .state == "PENDING") then "PENDING" else "CLEAN" end' "${items_file}" -r)"
  jq -cs \
    --arg label "${label}" \
    --arg site_path "${site_path}" \
    --arg state "${state}" \
    '{label:$label,site_path:$site_path,active:true,state:$state,items:.,warning_count:([.[].warning_count]|add//0),error_count:([.[].error_count]|add//0)}' \
    "${items_file}"
  rm -f "${items_file}"
}

sync_component() {
  local item_json="$1"
  local source_path target_path state pending retry synced
  local combined_warnings combined_warning_count

  source_path="$(jq -r '.source_path' <<<"${item_json}")"
  target_path="$(jq -r '.target_path' <<<"${item_json}")"
  run_rsync_operation "sync" "${source_path}" "${target_path}"

  combined_warnings="$(jq -cn --argjson before "$(jq -c '.warnings' <<<"${item_json}")" --argjson after "${RSYNC_WARNINGS_JSON}" '$before + $after | unique | .[:10]')"
  combined_warning_count=$(( $(jq -r '.warning_count' <<<"${item_json}") + RSYNC_WARNING_COUNT ))

  state="CLEAN"
  pending=false
  retry=false
  synced=true
  if [[ "${RSYNC_ERROR_COUNT}" -gt 0 ]]; then
    state="ERROR"
    pending=false
    synced=false
  elif [[ "${RSYNC_EXIT_CODE}" -eq 24 ]]; then
    state="PENDING"
    pending=true
    retry=true
    synced=false
  fi

  jq -cn \
    --argjson item "${item_json}" \
    --arg state "${state}" \
    --argjson pending "${pending}" \
    --argjson retry "${retry}" \
    --argjson synced "${synced}" \
    --argjson warnings "${combined_warnings}" \
    --argjson warning_count "${combined_warning_count}" \
    --argjson errors "${RSYNC_ERRORS_JSON}" \
    --argjson error_count "${RSYNC_ERROR_COUNT}" \
    --argjson exit_code "${RSYNC_EXIT_CODE}" \
    '$item + {state:$state,pending:$pending,sync_required:false,retry:$retry,synced:$synced,changes:[],change_count:0,warnings:$warnings,warning_count:$warning_count,errors:$errors,error_count:$error_count,rsync_exit_code:$exit_code}'
}

sync_analyzed_target() {
  local target_json="$1"
  local state items_file item_json updated_item components warnings errors

  state="$(jq -r '.state' <<<"${target_json}")"
  if [[ "${state}" == "MISSING" ]]; then
    printf '%s\n' "${target_json}"
    return
  fi
  if [[ "${state}" == "ERROR" && "$(jq -r '.items | length' <<<"${target_json}")" -eq 0 ]]; then
    errors="$(jq -r '.error_count // 0' <<<"${target_json}")"
    log_error "RSYNC_ERRORS" "target=$(jq -r '.label' <<<"${target_json}") count=${errors} reason=$(jq -r '.reason // "unknown"' <<<"${target_json}")"
    printf '%s\n' "${target_json}"
    return
  fi
  if [[ "${state}" == "CLEAN" ]]; then
    warnings="$(jq -r '.warning_count // 0' <<<"${target_json}")"
    if [[ "${warnings}" -gt 0 ]]; then
      log_warning "RSYNC_WARNINGS" "target=$(jq -r '.label' <<<"${target_json}") count=${warnings}"
    fi
    printf '%s\n' "${target_json}"
    return
  fi

  components="$(jq -r '[.items[] | select(.sync_required == true) | (.kind + "/" + .slug)] | join(",")' <<<"${target_json}")"
  if [[ -n "${components}" ]]; then
    log_info "CHANGES_DETECTED" "target=$(jq -r '.label' <<<"${target_json}") components=${components}"
  fi

  items_file="$(mktemp)"
  while IFS= read -r item_json; do
    [[ -n "${item_json}" ]] || continue
    if [[ "$(jq -r '.sync_required' <<<"${item_json}")" == "true" ]]; then
      updated_item="$(sync_component "${item_json}")"
      printf '%s\n' "${updated_item}" >>"${items_file}"
    else
      printf '%s\n' "${item_json}" >>"${items_file}"
    fi
  done < <(jq -c '.items[]' <<<"${target_json}")

  state="$(jq -s 'if any(.[]; .state == "ERROR") then "ERROR" elif any(.[]; .state == "PENDING") then "PENDING" else "CLEAN" end' "${items_file}" -r)"
  warnings="$(jq -s '[.[].warning_count] | add // 0' "${items_file}")"
  errors="$(jq -s '[.[].error_count] | add // 0' "${items_file}")"
  updated_item="$(jq -cs --argjson target "${target_json}" --arg state "${state}" --argjson warnings "${warnings}" --argjson errors "${errors}" '$target + {state:$state,items:.,warning_count:$warnings,error_count:$errors}' "${items_file}")"
  rm -f "${items_file}"

  components="$(jq -r '[.items[] | select(.synced == true) | (.kind + "/" + .slug)] | join(",")' <<<"${updated_item}")"
  if [[ -n "${components}" ]]; then
    log_info "COMPONENTS_SYNCED" "target=$(jq -r '.label' <<<"${updated_item}") components=${components}"
  fi
  if [[ "${warnings}" -gt 0 ]]; then
    log_warning "RSYNC_WARNINGS" "target=$(jq -r '.label' <<<"${updated_item}") count=${warnings}"
  fi
  if [[ "${errors}" -gt 0 ]]; then
    log_error "RSYNC_ERRORS" "target=$(jq -r '.label' <<<"${updated_item}") count=${errors}"
  fi

  printf '%s\n' "${updated_item}"
}

compose_status() {
  local targets_file="$1"
  local updated_at
  updated_at="$(iso_timestamp)"

  jq -cs \
    --arg updated_at "${updated_at}" \
    --arg source_site "${SOURCE_SITE}" \
    --argjson rsync_excludes "${RSYNC_EXCLUDES_JSON}" '
      def aggregate:
        if any(.[]; .state == "ERROR") then "ERROR"
        elif any(.[]; .state == "MISSING") then "MISSING"
        elif any(.[]; .state == "PENDING") then "PENDING"
        else "CLEAN"
        end;
      {
        updated_at:$updated_at,
        source_site:$source_site,
        rsync_excludes:$rsync_excludes,
        overall_state:aggregate,
        targets:.,
        synced_components:[.[] as $target | $target.items[]? | select(.synced == true) | (.kind + "/" + .slug)],
        warning_count:([.[].warning_count] | add // 0),
        error_count:([.[].error_count] | add // 0)
      }
      | if (.synced_components | length) > 0 then . + {last_sync_at:$updated_at} else . end
    ' "${targets_file}"
}

process_targets() {
  local config_path="$1"
  local target_label="$2"
  local operation="$3"
  local lock_dir="$4"
  local targets_file target_json label analyzed processed found_any lock_rc status_json

  targets_file="$(mktemp)"
  found_any=0
  while IFS= read -r target_json; do
    [[ -n "${target_json}" ]] || continue
    found_any=1
    label="$(jq -r '.label' <<<"${target_json}")"

    if acquire_target_lock "${label}" "${lock_dir}"; then
      :
    else
      lock_rc=$?
      rm -f "${targets_file}"
      return "${lock_rc}"
    fi

    analyzed="$(analyze_target "${target_json}")"
    if [[ "${operation}" == "sync" ]]; then
      processed="$(sync_analyzed_target "${analyzed}")"
    else
      processed="${analyzed}"
    fi
    printf '%s\n' "${processed}" >>"${targets_file}"
    release_target_lock
  done < <(iter_targets "${config_path}" "${target_label}")

  if [[ "${found_any}" -ne 1 ]]; then
    rm -f "${targets_file}"
    fail "target not found: ${target_label}"
  fi

  status_json="$(compose_status "${targets_file}")"
  rm -f "${targets_file}"
  printf '%s\n' "${status_json}"
}

print_human_status() {
  local status_json="$1"
  jq -r '
    .targets[] as $target
    | if $target.state == "CLEAN" then "CLEAN \($target.label)"
      elif $target.state == "MISSING" then "MISSING \($target.label) \($target.reason // "TARGET_MISSING")"
      elif $target.state == "ERROR" and ($target.items | length) == 0 then "ERROR \($target.label) \($target.reason // "unknown")"
      else $target.items[] | select(.state != "CLEAN") | "\(.state) \($target.label) \(.kind)/\(.slug)"
      end
  ' <<<"${status_json}"
}

on_exit() {
  local exit_code=$?
  release_target_lock
  if [[ "${WATCH_ACTIVE}" -eq 1 && "${STOP_LOGGED}" -eq 0 ]]; then
    log_info "WATCH_STOP" "exit_code=${exit_code}"
    STOP_LOGGED=1
  fi
}
trap on_exit EXIT
trap 'exit 0' TERM INT

watch_target() {
  local config_path="$1"
  local target_label="$2"
  local interval="$3"
  local max_interval="$4"
  local debounce="$5"
  local max_cycles="$6"
  local status_file="$7"
  local lock_dir="$8"
  local cycle=0 current_interval status_json state synced_count

  WATCH_ACTIVE=1
  current_interval="${interval}"
  log_info "WATCH_START" "target=${target_label} interval=${interval}s max_interval=${max_interval}s debounce=${debounce}s"

  while true; do
    if awk -v delay="${debounce}" 'BEGIN { exit !(delay > 0) }'; then
      sleep "${debounce}"
    fi

    status_json="$(process_targets "${config_path}" "${target_label}" "sync" "${lock_dir}")" || return $?
    cycle=$((cycle + 1))
    status_json="$(jq -cn \
      --argjson payload "${status_json}" \
      --argjson cycle "${cycle}" \
      --arg poll_interval "${current_interval}" \
      '$payload + {watcher:{cycle:$cycle,poll_interval_seconds:($poll_interval|tonumber)}}')"
    write_status_file "${status_file}" "${status_json}"

    state="$(jq -r '.overall_state' <<<"${status_json}")"
    synced_count="$(jq -r '.synced_components | length' <<<"${status_json}")"
    if [[ "${state}" == "MISSING" ]]; then
      log_warning "TARGET_MISSING" "target=${target_label}; watcher stopping until explicitly started after the site returns"
      break
    fi

    if [[ "${max_cycles}" -gt 0 && "${cycle}" -ge "${max_cycles}" ]]; then
      break
    fi

    if [[ "${state}" == "CLEAN" && "${synced_count}" -eq 0 ]]; then
      current_interval="$(next_backoff "${current_interval}" "${max_interval}")"
    else
      current_interval="${interval}"
    fi
    sleep "${current_interval}"
  done

  log_info "WATCH_STOP" "target=${target_label} cycles=${cycle}"
  STOP_LOGGED=1
  WATCH_ACTIVE=0
}

main() {
  require_tool jq
  require_tool rsync

  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  local config_path="${DEFAULT_CONFIG_PATH}"
  local target_label=""
  local interval="${DEFAULT_INTERVAL}"
  local max_interval="${DEFAULT_MAX_INTERVAL}"
  local debounce="${DEFAULT_DEBOUNCE}"
  local max_cycles=0
  local output_json=0
  local status_file=""
  local lock_dir="${DEFAULT_LOCK_DIR}"
  local log_file=""
  local error_log_file=""
  local log_max_bytes="${DEFAULT_LOG_MAX_BYTES}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || fail "--config requires a value"
        config_path="$2"; shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || fail "--target requires a value"
        target_label="$2"; shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || fail "--interval requires a value"
        interval="$2"; shift 2
        ;;
      --max-interval)
        [[ $# -ge 2 ]] || fail "--max-interval requires a value"
        max_interval="$2"; shift 2
        ;;
      --debounce)
        [[ $# -ge 2 ]] || fail "--debounce requires a value"
        debounce="$2"; shift 2
        ;;
      --max-cycles)
        [[ $# -ge 2 ]] || fail "--max-cycles requires a value"
        max_cycles="$2"; shift 2
        ;;
      --status-file)
        [[ $# -ge 2 ]] || fail "--status-file requires a value"
        status_file="$2"; shift 2
        ;;
      --lock-dir)
        [[ $# -ge 2 ]] || fail "--lock-dir requires a value"
        lock_dir="${2%/}"; shift 2
        ;;
      --log-file)
        [[ $# -ge 2 ]] || fail "--log-file requires a value"
        log_file="$2"; shift 2
        ;;
      --error-log-file)
        [[ $# -ge 2 ]] || fail "--error-log-file requires a value"
        error_log_file="$2"; shift 2
        ;;
      --log-max-bytes)
        [[ $# -ge 2 ]] || fail "--log-max-bytes requires a value"
        log_max_bytes="$2"; shift 2
        ;;
      --json)
        output_json=1; shift
        ;;
      -h|--help)
        usage; exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  [[ "${max_cycles}" =~ ^[0-9]+$ ]] || fail "--max-cycles must be a non-negative integer"
  [[ "${log_max_bytes}" =~ ^[0-9]+$ && "${log_max_bytes}" -ge 128 ]] || fail "--log-max-bytes must be at least 128"
  is_positive_number "${interval}" || fail "--interval must be greater than zero"
  is_positive_number "${max_interval}" || fail "--max-interval must be greater than zero"
  is_nonnegative_number "${debounce}" || fail "--debounce must be non-negative"
  awk -v minimum="${interval}" -v maximum="${max_interval}" 'BEGIN { exit !(maximum >= minimum) }' || fail "--max-interval must be at least --interval"

  LOG_FILE="${log_file}"
  ERROR_LOG_FILE="${error_log_file}"
  LOG_MAX_BYTES="${log_max_bytes}"

  validate_config "${config_path}"
  load_global_config "${config_path}"

  local status_json
  case "${command}" in
    status)
      status_json="$(process_targets "${config_path}" "${target_label}" "status" "${lock_dir}")" || exit $?
      write_status_file "${status_file}" "${status_json}"
      if [[ "${output_json}" -eq 1 ]]; then
        printf '%s\n' "${status_json}"
      else
        print_human_status "${status_json}"
      fi
      ;;
    sync)
      status_json="$(process_targets "${config_path}" "${target_label}" "sync" "${lock_dir}")" || exit $?
      write_status_file "${status_file}" "${status_json}"
      local result_state
      result_state="$(jq -r '.overall_state' <<<"${status_json}")"
      if [[ "${output_json}" -eq 1 ]]; then
        printf '%s\n' "${status_json}"
      else
        local synced
        synced="$(jq -r '.synced_components | join(",")' <<<"${status_json}")"
        if [[ -n "${synced}" ]]; then
          printf 'SYNCED %s %s\n' "${target_label:-all}" "${synced}"
        fi
        if [[ "${result_state}" == "ERROR" ]]; then
          print_human_status "${status_json}" >&2
        fi
      fi
      [[ "${result_state}" != "ERROR" ]] || return 1
      ;;
    watch)
      [[ -n "${target_label}" ]] || fail "watch requires --target to avoid scanning every target from one polling loop"
      watch_target "${config_path}" "${target_label}" "${interval}" "${max_interval}" "${debounce}" "${max_cycles}" "${status_file}" "${lock_dir}"
      ;;
    *)
      usage
      fail "unknown command: ${command}"
      ;;
  esac
}

main "$@"

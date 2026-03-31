#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_CONFIG_PATH="${ROOT_DIR}/config/wp-code-mirror.config.json"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-sync.sh status [--config <path>] [--target <label>] [--json] [--status-file <path>]
  bash scripts/wp-code-sync.sh sync   [--config <path>] [--target <label>] [--json] [--status-file <path>]
  bash scripts/wp-code-sync.sh watch  [--config <path>] [--target <label>] [--interval <seconds>] [--status-file <path>]
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_tool() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || fail "missing required tool: ${name}"
}

trim_trailing_slash() {
  local path="$1"
  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "${path}"
}

iso_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_status_file() {
  local status_path="$1"
  local json_payload="$2"

  [[ -n "${status_path}" ]] || return 0
  mkdir -p "$(dirname "${status_path}")"
  printf '%s\n' "${json_payload}" | jq '.' >"${status_path}"
}

validate_config() {
  local config_path="$1"

  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"

  jq -e '
    (.source_site | type == "string" and length > 1) and
    (.targets | type == "array" and length > 0) and
    all(.targets[];
      (.label | type == "string" and length > 0) and
      (.site_path | type == "string" and length > 1) and
      ((.themes // []) | type == "array") and
      ((.plugins // []) | type == "array")
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
    ((.plugins // [])[] | "plugins\t" + .)
  ' <<<"${target_json}"
}

ensure_target_site() {
  local site_path="$1"
  [[ -d "${site_path}/wp-content/themes" ]] || fail "target themes directory missing: ${site_path}/wp-content/themes"
  [[ -d "${site_path}/wp-content/plugins" ]] || fail "target plugins directory missing: ${site_path}/wp-content/plugins"
}

rsync_changes() {
  local source_path="$1"
  local target_path="$2"
  local output

  output="$(rsync -a --delete --dry-run --itemize-changes "${RSYNC_EXCLUDES[@]}" "${source_path}/" "${target_path}/")"
  printf '%s' "${output}"
}

sync_tree() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "${target_path}"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "${source_path}/" "${target_path}/"
}

build_target_status_json() {
  local target_json="$1"
  local label site_path safe_site_path kind slug source_path target_path changes
  local any_pending items_file state

  label="$(jq -r '.label' <<<"${target_json}")"
  site_path="$(jq -r '.site_path' <<<"${target_json}")"
  site_path="$(trim_trailing_slash "${site_path}")"
  ensure_target_site "${site_path}"

  any_pending=0
  items_file="$(mktemp)"
  trap 'rm -f "${items_file}"' RETURN

  while IFS=$'\t' read -r kind slug; do
    [[ -n "${kind}" ]] || continue
    source_path="${SOURCE_SITE}/wp-content/${kind}/${slug}"
    target_path="${site_path}/wp-content/${kind}/${slug}"

    [[ -d "${source_path}" ]] || fail "source item missing: ${source_path}"

    changes="$(rsync_changes "${source_path}" "${target_path}")"
    if [[ -n "${changes}" ]]; then
      any_pending=1
    fi

    jq -cn \
      --arg kind "${kind}" \
      --arg slug "${slug}" \
      --arg source_path "${source_path}" \
      --arg target_path "${target_path}" \
      --arg changes "${changes}" \
      '{
        kind: $kind,
        slug: $slug,
        source_path: $source_path,
        target_path: $target_path,
        pending: ($changes != ""),
        changes: ($changes | if . == "" then [] else split("\n") end)
      }' >>"${items_file}"
  done < <(iter_target_items "${target_json}")

  if [[ "${any_pending}" -eq 1 ]]; then
    state="PENDING"
  else
    state="CLEAN"
  fi

  jq -cs \
    --arg label "${label}" \
    --arg site_path "${site_path}" \
    --arg state "${state}" \
    '{
      label: $label,
      site_path: $site_path,
      state: $state,
      items: .
    }' "${items_file}"
}

build_status_json() {
  local config_path="$1"
  local target_label="$2"
  local targets_file target_json found_any overall_state

  targets_file="$(mktemp)"
  trap 'rm -f "${targets_file}"' RETURN

  found_any=0
  while IFS= read -r target_json; do
    [[ -n "${target_json}" ]] || continue
    found_any=1
    build_target_status_json "${target_json}" >>"${targets_file}"
  done < <(iter_targets "${config_path}" "${target_label}")

  [[ "${found_any}" -eq 1 ]] || fail "target not found: ${target_label}"

  if jq -e 'any(.state == "PENDING")' "${targets_file}" >/dev/null 2>&1; then
    overall_state="PENDING"
  else
    overall_state="CLEAN"
  fi

  jq -cs \
    --arg updated_at "$(iso_timestamp)" \
    --arg source_site "${SOURCE_SITE}" \
    --arg overall_state "${overall_state}" \
    '{
      updated_at: $updated_at,
      source_site: $source_site,
      overall_state: $overall_state,
      targets: .
    }' "${targets_file}"
}

render_human_status() {
  local status_json="$1"
  jq -r '
    .targets[]
    | if .state == "PENDING" then
        .items[]
        | select(.pending)
        | "PENDING \(.target_path | capture("/wp-content/(?<kind>[^/]+)/(?<slug>[^/]+)$").kind)/\(.target_path | capture("/wp-content/(?<kind>[^/]+)/(?<slug>[^/]+)$").slug)"
      else
        "CLEAN \(.label)"
      end
  ' <<<"${status_json}" | awk '
    /^PENDING / {
      sub(/^PENDING /, "")
      split($0, parts, "/")
      kind = parts[1]
      slug = parts[2]
      print "PENDING " target_label " " kind "/" slug
      next
    }
    { print }
  ' target_label=""
}

print_human_status() {
  local status_json="$1"
  jq -r '
    .targets[] as $target
    | if $target.state == "PENDING" then
        $target.items[]
        | select(.pending)
        | "PENDING \($target.label) \(.kind)/\(.slug)"
      else
        "CLEAN \($target.label)"
      end
  ' <<<"${status_json}"
}

sync_target() {
  local target_json="$1"
  local label site_path kind slug source_path target_path

  label="$(jq -r '.label' <<<"${target_json}")"
  site_path="$(jq -r '.site_path' <<<"${target_json}")"
  site_path="$(trim_trailing_slash "${site_path}")"

  [[ "${site_path}" != "${SOURCE_SITE}" ]] || fail "source and target paths must differ: ${site_path}"
  ensure_target_site "${site_path}"

  while IFS=$'\t' read -r kind slug; do
    [[ -n "${kind}" ]] || continue
    source_path="${SOURCE_SITE}/wp-content/${kind}/${slug}"
    target_path="${site_path}/wp-content/${kind}/${slug}"

    [[ -d "${source_path}" ]] || fail "source item missing: ${source_path}"
    sync_tree "${source_path}" "${target_path}"
    echo "SYNCED ${label} ${kind}/${slug}"
  done < <(iter_target_items "${target_json}")
}

target_has_changes() {
  local target_json="$1"
  local site_path kind slug source_path target_path changes

  site_path="$(jq -r '.site_path' <<<"${target_json}")"
  site_path="$(trim_trailing_slash "${site_path}")"

  while IFS=$'\t' read -r kind slug; do
    [[ -n "${kind}" ]] || continue
    source_path="${SOURCE_SITE}/wp-content/${kind}/${slug}"
    target_path="${site_path}/wp-content/${kind}/${slug}"
    changes="$(rsync_changes "${source_path}" "${target_path}")"
    if [[ -n "${changes}" ]]; then
      return 0
    fi
  done < <(iter_target_items "${target_json}")

  return 1
}

watch_targets() {
  local config_path="$1"
  local target_label="$2"
  local interval="$3"
  local status_file="$4"
  local target_json found_any status_json

  while true; do
    found_any=0
    while IFS= read -r target_json; do
      [[ -n "${target_json}" ]] || continue
      found_any=1
      if target_has_changes "${target_json}"; then
        sync_target "${target_json}"
      fi
    done < <(iter_targets "${config_path}" "${target_label}")

    [[ "${found_any}" -eq 1 ]] || fail "target not found: ${target_label}"

    status_json="$(build_status_json "${config_path}" "${target_label}")"
    write_status_file "${status_file}" "${status_json}"
    sleep "${interval}"
  done
}

main() {
  require_tool jq
  require_tool rsync

  local command="${1:-}"
  [[ -n "${command}" ]] || {
    usage
    exit 1
  }
  shift || true

  local config_path="${DEFAULT_CONFIG_PATH}"
  local target_label=""
  local interval="2"
  local output_json=0
  local status_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || fail "--config requires a value"
        config_path="$2"
        shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || fail "--target requires a value"
        target_label="$2"
        shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || fail "--interval requires a value"
        interval="$2"
        shift 2
        ;;
      --status-file)
        [[ $# -ge 2 ]] || fail "--status-file requires a value"
        status_file="$2"
        shift 2
        ;;
      --json)
        output_json=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done

  validate_config "${config_path}"
  load_global_config "${config_path}"

  local target_json found_any status_json
  case "${command}" in
    status)
      status_json="$(build_status_json "${config_path}" "${target_label}")"
      write_status_file "${status_file}" "${status_json}"
      if [[ "${output_json}" -eq 1 ]]; then
        printf '%s\n' "${status_json}"
      else
        print_human_status "${status_json}"
      fi
      ;;
    sync)
      found_any=0
      while IFS= read -r target_json; do
        [[ -n "${target_json}" ]] || continue
        found_any=1
        if [[ "${output_json}" -eq 0 ]]; then
          sync_target "${target_json}"
        else
          sync_target "${target_json}" >/dev/null
        fi
      done < <(iter_targets "${config_path}" "${target_label}")
      [[ "${found_any}" -eq 1 ]] || fail "target not found: ${target_label}"

      status_json="$(build_status_json "${config_path}" "${target_label}")"
      status_json="$(jq -cn \
        --argjson payload "${status_json}" \
        --arg last_sync_at "$(iso_timestamp)" \
        '$payload + {last_sync_at: $last_sync_at}')"
      write_status_file "${status_file}" "${status_json}"

      if [[ "${output_json}" -eq 1 ]]; then
        printf '%s\n' "${status_json}"
      fi
      ;;
    watch)
      watch_targets "${config_path}" "${target_label}" "${interval}" "${status_file}"
      ;;
    *)
      usage
      fail "unknown command: ${command}"
      ;;
  esac
}

main "$@"

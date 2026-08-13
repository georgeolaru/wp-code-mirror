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
SYNC_SCRIPT="${SCRIPT_DIR}/wp-code-sync.sh"

detect_default_storage_root() {
  if [[ "${ROOT_DIR}" == */wp-content/plugins/* ]]; then
    printf '%s/wp-content/uploads/wp-code-mirror\n' "${ROOT_DIR%/wp-content/plugins/*}"
    return
  fi

  printf '%s\n' "${ROOT_DIR}"
}

DEFAULT_STORAGE_ROOT="$(detect_default_storage_root)"
DEFAULT_CONFIG_PATH="${DEFAULT_STORAGE_ROOT}/config/wp-code-mirror.config.json"
DEFAULT_RUNTIME_DIR="${DEFAULT_STORAGE_ROOT}/tmp"
DEFAULT_INTERVAL="15"
DEFAULT_MAX_INTERVAL="300"
DEFAULT_DEBOUNCE="1"
DEFAULT_LOG_MAX_BYTES="1048576"

resolve_home_dir() {
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi

  local user_name home_path
  user_name="$(id -un)"
  home_path="$(dscl . -read "/Users/${user_name}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [[ -z "${home_path}" ]]; then
    home_path="$(eval printf '%s' "~${user_name}")"
  fi

  [[ -n "${home_path}" ]] || fail "could not determine user home directory"
  printf '%s\n' "${home_path}"
}

USER_HOME_DIR="$(resolve_home_dir)"
LAUNCH_AGENTS_DIR="${USER_HOME_DIR}/Library/LaunchAgents"
RUNTIME_DIR="${DEFAULT_RUNTIME_DIR}"
RUNNER_DIR=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-sync-service.sh install      --target <label> [watch options]
  bash scripts/wp-code-sync-service.sh start        --target <label> [--config <path>] [--runtime-dir <path>]
  bash scripts/wp-code-sync-service.sh stop         --target <label> [--runtime-dir <path>]
  bash scripts/wp-code-sync-service.sh restart      --target <label> [watch options]
  bash scripts/wp-code-sync-service.sh uninstall    --target <label> [--runtime-dir <path>]
  bash scripts/wp-code-sync-service.sh status       --target <label> [--runtime-dir <path>] [--json]
  bash scripts/wp-code-sync-service.sh start-active [watch options]
  bash scripts/wp-code-sync-service.sh upgrade-active [watch options]

Watch options:
  --config <path> --runtime-dir <path> --interval <seconds>
  --max-interval <seconds> --debounce <seconds> --log-max-bytes <bytes>

start-active installs/refreshes and starts only targets with active=true and a present site path.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

validate_watch_options() {
  local interval="$1"
  local max_interval="$2"
  local debounce="$3"
  local log_max_bytes="$4"

  awk -v value="${interval}" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' \
    || fail "--interval must be greater than zero"
  awk -v value="${max_interval}" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }' \
    || fail "--max-interval must be greater than zero"
  awk -v minimum="${interval}" -v maximum="${max_interval}" 'BEGIN { exit !(maximum >= minimum) }' \
    || fail "--max-interval must be at least --interval"
  awk -v value="${debounce}" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }' \
    || fail "--debounce must be non-negative"
  [[ "${log_max_bytes}" =~ ^[0-9]+$ && "${log_max_bytes}" -ge 128 ]] \
    || fail "--log-max-bytes must be at least 128"
}

sanitize_label() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

resolve_runner_dir() {
  local runtime_dir="$1"
  if [[ "$(basename "${runtime_dir}")" == "tmp" ]]; then
    printf '%s/bin\n' "$(dirname "${runtime_dir}")"
  else
    printf '%s/bin\n' "${runtime_dir}"
  fi
}

service_label() {
  printf 'com.wp-code-mirror.sync.%s\n' "$(sanitize_label "$1")"
}

plist_path() {
  printf '%s/%s.plist\n' "${LAUNCH_AGENTS_DIR}" "$(service_label "$1")"
}

runner_path() {
  printf '%s/wp-code-mirror-watch-%s\n' "${RUNNER_DIR}" "$(sanitize_label "$1")"
}

status_file_path() {
  printf '%s/wp-code-mirror-%s-status.json\n' "${RUNTIME_DIR}" "$(sanitize_label "$1")"
}

stdout_log_path() {
  printf '%s/wp-code-mirror-%s.log\n' "${RUNTIME_DIR}" "$(sanitize_label "$1")"
}

stderr_log_path() {
  printf '%s/wp-code-mirror-%s.error.log\n' "${RUNTIME_DIR}" "$(sanitize_label "$1")"
}

lock_dir_path() {
  printf '%s/locks\n' "${RUNTIME_DIR}"
}

ensure_config_file() {
  local config_path="$1"
  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  jq -e '.targets | type == "array"' "${config_path}" >/dev/null || fail "invalid config: ${config_path}"
}

target_json() {
  local config_path="$1"
  local target_label="$2"
  jq -c --arg label "${target_label}" '.targets[] | select(.label == $label)' "${config_path}"
}

ensure_installable_target() {
  local config_path="$1"
  local target_label="$2"
  local target site_path active

  target="$(target_json "${config_path}" "${target_label}")"
  [[ -n "${target}" ]] || fail "target not found in config: ${target_label}"
  active="$(jq -r 'if has("active") then .active else true end' <<<"${target}")"
  [[ "${active}" == "true" ]] || fail "target is inactive: ${target_label}"
  site_path="$(jq -r '.site_path' <<<"${target}")"
  [[ -d "${site_path}/wp-content/themes" && -d "${site_path}/wp-content/plugins" ]] \
    || fail "target site missing or invalid: ${target_label} (${site_path})"
}

launchctl_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

is_loaded() {
  local target_label="$1"
  launchctl print "$(launchctl_domain)/$(service_label "${target_label}")" >/dev/null 2>&1
}

write_runner() {
  local config_path="$1"
  local target_label="$2"
  local interval="$3"
  local max_interval="$4"
  local debounce="$5"
  local log_max_bytes="$6"
  local runner temporary

  mkdir -p "${RUNNER_DIR}" "${RUNTIME_DIR}"
  runner="$(runner_path "${target_label}")"
  temporary="${runner}.tmp.$$"
  cat >"${temporary}" <<EOF
#!/bin/bash
exec /bin/bash "${SYNC_SCRIPT}" watch \\
  --config "${config_path}" \\
  --target "${target_label}" \\
  --interval "${interval}" \\
  --max-interval "${max_interval}" \\
  --debounce "${debounce}" \\
  --status-file "$(status_file_path "${target_label}")" \\
  --lock-dir "$(lock_dir_path)" \\
  --log-file "$(stdout_log_path "${target_label}")" \\
  --error-log-file "$(stderr_log_path "${target_label}")" \\
  --log-max-bytes "${log_max_bytes}"
EOF
  chmod +x "${temporary}"
  mv -f "${temporary}" "${runner}"
}

write_plist() {
  local target_label="$1"
  local plist runner label temporary

  mkdir -p "${LAUNCH_AGENTS_DIR}" "${RUNTIME_DIR}"
  plist="$(plist_path "${target_label}")"
  runner="$(runner_path "${target_label}")"
  label="$(service_label "${target_label}")"
  temporary="${plist}.tmp.$$"

  cat >"${temporary}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "${label}")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${runner}")</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "${ROOT_DIR}")</string>
</dict>
</plist>
EOF
  mv -f "${temporary}" "${plist}"
}

install_definition() {
  local config_path="$1"
  local target_label="$2"
  local interval="$3"
  local max_interval="$4"
  local debounce="$5"
  local log_max_bytes="$6"

  ensure_installable_target "${config_path}" "${target_label}"
  stop_service "${target_label}"
  write_runner "${config_path}" "${target_label}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"
  write_plist "${target_label}"
}

start_service() {
  local target_label="$1"
  local plist
  plist="$(plist_path "${target_label}")"
  [[ -f "${plist}" ]] || fail "plist not found: ${plist}"

  if is_loaded "${target_label}"; then
    launchctl kickstart -k "$(launchctl_domain)/$(service_label "${target_label}")"
  else
    launchctl bootstrap "$(launchctl_domain)" "${plist}"
  fi
}

stop_service() {
  local target_label="$1"
  local plist
  plist="$(plist_path "${target_label}")"

  if is_loaded "${target_label}"; then
    launchctl bootout "$(launchctl_domain)" "${plist}" >/dev/null 2>&1 || \
      launchctl bootout "$(launchctl_domain)/$(service_label "${target_label}")" >/dev/null 2>&1 || true
  fi
}

retire_definition() {
  local target_label="$1"
  stop_service "${target_label}"
  rm -f "$(plist_path "${target_label}")" "$(runner_path "${target_label}")"
}

service_status_json() {
  local target_label="$1"
  local label plist status_path stdout_log stderr_log runner installed running launchctl_output pid state sync_json

  label="$(service_label "${target_label}")"
  plist="$(plist_path "${target_label}")"
  runner="$(runner_path "${target_label}")"
  status_path="$(status_file_path "${target_label}")"
  stdout_log="$(stdout_log_path "${target_label}")"
  stderr_log="$(stderr_log_path "${target_label}")"

  [[ -f "${plist}" ]] && installed=1 || installed=0
  if is_loaded "${target_label}"; then
    launchctl_output="$(launchctl print "$(launchctl_domain)/${label}" 2>/dev/null || true)"
    pid="$(printf '%s\n' "${launchctl_output}" | awk -F'= ' '/pid = / {print $2; exit}')"
    state="$(printf '%s\n' "${launchctl_output}" | awk -F'= ' '/state = / {print $2; exit}')"
    if [[ "${state}" == "running" && "${pid}" =~ ^[0-9]+$ ]]; then
      running=1
    else
      running=0
    fi
  else
    running=0
    pid=""
    state="stopped"
  fi

  sync_json='null'
  if [[ -s "${status_path}" ]] && jq -e '.' "${status_path}" >/dev/null 2>&1; then
    sync_json="$(jq -c '.' "${status_path}")"
  fi

  jq -cn \
    --arg label "${label}" \
    --arg target_label "${target_label}" \
    --arg plist_path "${plist}" \
    --arg runner_path "${runner}" \
    --arg status_file "${status_path}" \
    --arg stdout_log "${stdout_log}" \
    --arg stderr_log "${stderr_log}" \
    --arg pid "${pid}" \
    --arg state "${state}" \
    --argjson installed "${installed}" \
    --argjson running "${running}" \
    --argjson sync_status "${sync_json}" \
    '{
      target_label:$target_label,
      service_label:$label,
      installed:($installed == 1),
      running:($running == 1),
      pid:(if $pid == "" then null else ($pid|tonumber) end),
      state:$state,
      plist_path:$plist_path,
      runner_path:$runner_path,
      status_file:$status_file,
      stdout_log:$stdout_log,
      stderr_log:$stderr_log,
      sync_status:$sync_status
    }'
}

process_active_targets() {
  local config_path="$1"
  local interval="$2"
  local max_interval="$3"
  local debounce="$4"
  local log_max_bytes="$5"
  local start_watchers="$6"
  local target label site_path active started=0 upgraded=0 skipped=0 stopped=0

  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    label="$(jq -r '.label' <<<"${target}")"
    site_path="$(jq -r '.site_path' <<<"${target}")"
    active="$(jq -r 'if has("active") then .active else true end' <<<"${target}")"
    if [[ "${active}" != "true" ]]; then
      retire_definition "${label}"
      printf 'STOPPED %s INACTIVE\n' "${label}"
      stopped=$((stopped + 1))
      continue
    fi
    if [[ ! -d "${site_path}/wp-content/themes" || ! -d "${site_path}/wp-content/plugins" ]]; then
      retire_definition "${label}"
      printf 'SKIPPED %s TARGET_MISSING\n' "${label}" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "${start_watchers}" -eq 0 ]]; then
      stop_service "${label}"
    fi
    install_definition "${config_path}" "${label}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"
    if [[ "${start_watchers}" -eq 1 ]]; then
      start_service "${label}"
      printf 'STARTED %s\n' "${label}"
      started=$((started + 1))
    else
      printf 'UPGRADED %s\n' "${label}"
      upgraded=$((upgraded + 1))
    fi
  done < <(jq -c '.targets[]' "${config_path}")

  printf 'Active watchers started: %s; definitions upgraded: %s; inactive retired: %s; missing retired: %s\n' \
    "${started}" "${upgraded}" "${stopped}" "${skipped}"
}

main() {
  command -v jq >/dev/null 2>&1 || fail "missing required tool: jq"
  command -v launchctl >/dev/null 2>&1 || fail "missing required tool: launchctl"

  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  local config_path="${DEFAULT_CONFIG_PATH}"
  local runtime_dir="${DEFAULT_RUNTIME_DIR}"
  local target_label=""
  local interval="${DEFAULT_INTERVAL}"
  local max_interval="${DEFAULT_MAX_INTERVAL}"
  local debounce="${DEFAULT_DEBOUNCE}"
  local log_max_bytes="${DEFAULT_LOG_MAX_BYTES}"
  local output_json=0

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
      --runtime-dir)
        [[ $# -ge 2 ]] || fail "--runtime-dir requires a value"
        runtime_dir="$2"; shift 2
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

  RUNTIME_DIR="${runtime_dir%/}"
  RUNNER_DIR="$(resolve_runner_dir "${RUNTIME_DIR}")"
  validate_watch_options "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"

  case "${command}" in
    start-active|upgrade-active)
      ensure_config_file "${config_path}"
      if [[ "${command}" == "start-active" ]]; then
        process_active_targets "${config_path}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}" 1
      else
        process_active_targets "${config_path}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}" 0
      fi
      exit 0
      ;;
  esac

  [[ -n "${target_label}" ]] || fail "--target is required"

  case "${command}" in
    install)
      ensure_config_file "${config_path}"
      install_definition "${config_path}" "${target_label}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    start)
      ensure_config_file "${config_path}"
      install_definition "${config_path}" "${target_label}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    stop)
      stop_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    restart)
      ensure_config_file "${config_path}"
      install_definition "${config_path}" "${target_label}" "${interval}" "${max_interval}" "${debounce}" "${log_max_bytes}"
      stop_service "${target_label}"
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    uninstall)
      retire_definition "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    status)
      if [[ "${output_json}" -eq 1 ]]; then
        service_status_json "${target_label}"
      else
        service_status_json "${target_label}" | jq '.'
      fi
      ;;
    *)
      usage
      fail "unknown command: ${command}"
      ;;
  esac
}

main "$@"

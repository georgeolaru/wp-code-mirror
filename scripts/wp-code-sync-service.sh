#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-sync-service.sh install  --target <label> [--config <path>] [--runtime-dir <path>] [--interval <seconds>]
  bash scripts/wp-code-sync-service.sh start    --target <label> [--config <path>] [--runtime-dir <path>] [--interval <seconds>]
  bash scripts/wp-code-sync-service.sh stop     --target <label>
  bash scripts/wp-code-sync-service.sh restart  --target <label> [--config <path>] [--runtime-dir <path>] [--interval <seconds>]
  bash scripts/wp-code-sync-service.sh uninstall --target <label>
  bash scripts/wp-code-sync-service.sh status   --target <label> [--runtime-dir <path>] [--json]
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

sanitize_label() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

service_label() {
  printf 'com.wp-code-mirror.sync.%s\n' "$(sanitize_label "$1")"
}

plist_path() {
  printf '%s/%s.plist\n' "${LAUNCH_AGENTS_DIR}" "$(service_label "$1")"
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

ensure_target_exists() {
  local config_path="$1"
  local target_label="$2"

  jq -e --arg label "${target_label}" '.targets[] | select(.label == $label)' "${config_path}" >/dev/null \
    || fail "target not found in config: ${target_label}"
}

launchctl_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

is_loaded() {
  local target_label="$1"
  launchctl print "$(launchctl_domain)/$(service_label "${target_label}")" >/dev/null 2>&1
}

write_plist() {
  local config_path="$1"
  local target_label="$2"
  local interval="$3"
  local plist output_status output_log error_log label

  mkdir -p "${LAUNCH_AGENTS_DIR}" "${RUNTIME_DIR}"

  plist="$(plist_path "${target_label}")"
  output_status="$(status_file_path "${target_label}")"
  output_log="$(stdout_log_path "${target_label}")"
  error_log="$(stderr_log_path "${target_label}")"
  label="$(service_label "${target_label}")"

  cat >"${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SYNC_SCRIPT}</string>
    <string>watch</string>
    <string>--config</string>
    <string>${config_path}</string>
    <string>--target</string>
    <string>${target_label}</string>
    <string>--interval</string>
    <string>${interval}</string>
    <string>--status-file</string>
    <string>${output_status}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${output_log}</string>
  <key>StandardErrorPath</key>
  <string>${error_log}</string>
  <key>WorkingDirectory</key>
  <string>${ROOT_DIR}</string>
</dict>
</plist>
EOF
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

service_status_json() {
  local target_label="$1"
  local label plist status_path stdout_log stderr_log installed running launchctl_output pid state sync_json

  label="$(service_label "${target_label}")"
  plist="$(plist_path "${target_label}")"
  status_path="$(status_file_path "${target_label}")"
  stdout_log="$(stdout_log_path "${target_label}")"
  stderr_log="$(stderr_log_path "${target_label}")"

  if [[ -f "${plist}" ]]; then
    installed=1
  else
    installed=0
  fi

  if is_loaded "${target_label}"; then
    running=1
    launchctl_output="$(launchctl print "$(launchctl_domain)/${label}" 2>/dev/null || true)"
    pid="$(printf '%s\n' "${launchctl_output}" | awk -F'= ' '/pid = / {print $2; exit}')"
    state="$(printf '%s\n' "${launchctl_output}" | awk -F'= ' '/state = / {print $2; exit}')"
  else
    running=0
    pid=""
    state="stopped"
  fi

  if [[ -f "${status_path}" ]]; then
    sync_json="$(jq -c '.' "${status_path}")"
  else
    sync_json='null'
  fi

  jq -cn \
    --arg label "${label}" \
    --arg target_label "${target_label}" \
    --arg plist_path "${plist}" \
    --arg status_file "${status_path}" \
    --arg stdout_log "${stdout_log}" \
    --arg stderr_log "${stderr_log}" \
    --arg pid "${pid}" \
    --arg state "${state}" \
    --argjson installed "${installed}" \
    --argjson running "${running}" \
    --argjson sync_status "${sync_json}" \
    '{
      target_label: $target_label,
      service_label: $label,
      installed: ($installed == 1),
      running: ($running == 1),
      pid: (if $pid == "" then null else ($pid | tonumber) end),
      state: $state,
      plist_path: $plist_path,
      status_file: $status_file,
      stdout_log: $stdout_log,
      stderr_log: $stderr_log,
      sync_status: $sync_status
    }'
}

main() {
  command -v jq >/dev/null 2>&1 || fail "missing required tool: jq"
  command -v launchctl >/dev/null 2>&1 || fail "missing required tool: launchctl"

  local command="${1:-}"
  [[ -n "${command}" ]] || {
    usage
    exit 1
  }
  shift || true

  local config_path="${DEFAULT_CONFIG_PATH}"
  local runtime_dir="${DEFAULT_RUNTIME_DIR}"
  local target_label=""
  local interval="2"
  local output_json=0

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
      --runtime-dir)
        [[ $# -ge 2 ]] || fail "--runtime-dir requires a value"
        runtime_dir="$2"
        shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || fail "--interval requires a value"
        interval="$2"
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

  [[ -n "${target_label}" ]] || fail "--target is required"
  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  ensure_target_exists "${config_path}" "${target_label}"
  RUNTIME_DIR="${runtime_dir%/}"

  case "${command}" in
    install)
      write_plist "${config_path}" "${target_label}" "${interval}"
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    start)
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    stop)
      stop_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    restart)
      write_plist "${config_path}" "${target_label}" "${interval}"
      stop_service "${target_label}"
      start_service "${target_label}"
      service_status_json "${target_label}" | jq '.'
      ;;
    uninstall)
      stop_service "${target_label}"
      rm -f "$(plist_path "${target_label}")"
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

#!/usr/bin/env bash

# Manage wp-code-mirror sync targets end to end: config entry + initial sync + launchd watcher,
# with optional WordPress Studio site creation/deletion. Companion to wp-code-sync.sh.

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
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-target.sh add <label> [options]
      --site-path <path>     Target site root (default: ~/Studio/<label>)
      --site-name <name>     Studio site display name (default: the label)
      --themes <a,b>         Comma-separated theme dirs to mirror
      --plugins <a,b>        Comma-separated plugin dirs to mirror
      --mu-plugins <a,b>     Comma-separated mu-plugin entries to mirror
      --create-site          Create the WordPress Studio site first (studio CLI)
      --interval <seconds>   Watcher interval (default: 2)
      --config <path>        Config file (default: uploads/wp-code-mirror/config/...)

  bash scripts/wp-code-target.sh remove <label> [options]
      --delete-site          Also delete the Studio site AND ITS FILES (asks unless --yes)
      --yes                  Skip the --delete-site confirmation prompt
      --config <path>        Config file

  bash scripts/wp-code-target.sh list [--config <path>]

Examples:
  bash scripts/wp-code-target.sh add lt-funnel-smoke --create-site \
    --themes anima-lt --plugins pixelgrade-assistant,style-manager,nova-blocks
  bash scripts/wp-code-target.sh remove lt-funnel-smoke --delete-site
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

plist_path_for() {
  printf '%s/com.wp-code-mirror.sync.%s.plist\n' "${LAUNCH_AGENTS_DIR}" "$1"
}

launchd_label_for() {
  printf 'com.wp-code-mirror.sync.%s\n' "$1"
}

target_exists() {
  local config_path="$1" label="$2"
  jq -e --arg label "${label}" '.targets[] | select(.label == $label)' "${config_path}" >/dev/null 2>&1
}

target_site_path() {
  local config_path="$1" label="$2"
  jq -r --arg label "${label}" '.targets[] | select(.label == $label) | .site_path' "${config_path}"
}

write_config() {
  local config_path="$1" json="$2" tmp
  tmp="$(mktemp)"
  printf '%s\n' "${json}" | jq '.' >"${tmp}" || fail "produced invalid config JSON; config untouched"
  mv "${tmp}" "${config_path}"
}

watcher_loaded() {
  # launchctl print is an exact lookup; grepping `launchctl list` is unreliable under pipefail
  # (grep -q SIGPIPEs launchctl).
  launchctl print "gui/$(id -u)/$(launchd_label_for "$1")" >/dev/null 2>&1
}

install_watcher() {
  local label="$1" config_path="$2" interval="$3"
  local plist tmp_dir
  plist="$(plist_path_for "${label}")"
  tmp_dir="${DEFAULT_STORAGE_ROOT}/tmp"
  mkdir -p "${tmp_dir}" "${LAUNCH_AGENTS_DIR}"

  cat >"${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(launchd_label_for "${label}")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/wp-code-sync.sh</string>
    <string>watch</string>
    <string>--config</string>
    <string>${config_path}</string>
    <string>--target</string>
    <string>${label}</string>
    <string>--interval</string>
    <string>${interval}</string>
    <string>--status-file</string>
    <string>${tmp_dir}/wp-code-mirror-${label}-status.json</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${tmp_dir}/wp-code-mirror-${label}.log</string>
  <key>StandardErrorPath</key>
  <string>${tmp_dir}/wp-code-mirror-${label}.error.log</string>
  <key>WorkingDirectory</key>
  <string>${ROOT_DIR}</string>
</dict>
</plist>
PLIST

  if watcher_loaded "${label}"; then
    launchctl bootout "gui/$(id -u)" "${plist}" 2>/dev/null || true
  fi
  launchctl bootstrap "gui/$(id -u)" "${plist}"
}

remove_watcher() {
  local label="$1" plist
  plist="$(plist_path_for "${label}")"

  if watcher_loaded "${label}"; then
    launchctl bootout "gui/$(id -u)" "${plist}" 2>/dev/null \
      || launchctl bootout "gui/$(id -u)/$(launchd_label_for "${label}")" 2>/dev/null \
      || true
  fi
  rm -f "${plist}"
}

csv_to_json_array() {
  local csv="${1:-}"
  if [[ -z "${csv}" ]]; then
    printf '[]\n'
    return
  fi
  printf '%s\n' "${csv}" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

cmd_add() {
  local label="$1"; shift
  local config_path="${DEFAULT_CONFIG_PATH}" site_path="" site_name="" themes_csv="" plugins_csv="" mu_csv="" create_site=0 interval=2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site-path) site_path="$2"; shift 2 ;;
      --site-name) site_name="$2"; shift 2 ;;
      --themes) themes_csv="$2"; shift 2 ;;
      --plugins) plugins_csv="$2"; shift 2 ;;
      --mu-plugins) mu_csv="$2"; shift 2 ;;
      --create-site) create_site=1; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --config) config_path="$2"; shift 2 ;;
      *) fail "unknown option for add: $1" ;;
    esac
  done

  [[ "${label}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "label must be kebab-case (got: ${label})"
  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  target_exists "${config_path}" "${label}" && fail "target already exists: ${label}"

  site_path="${site_path:-${HOME}/Studio/${label}}"
  site_name="${site_name:-${label}}"

  local themes plugins mu_plugins
  themes="$(csv_to_json_array "${themes_csv}")"
  plugins="$(csv_to_json_array "${plugins_csv}")"
  mu_plugins="$(csv_to_json_array "${mu_csv}")"
  [[ "$(printf '%s%s%s' "${themes}" "${plugins}" "${mu_plugins}")" != "[][][]" ]] \
    || fail "nothing to mirror: pass at least one of --themes / --plugins / --mu-plugins"

  if [[ "${create_site}" -eq 1 ]]; then
    require_tool studio
    [[ -d "${site_path}" ]] && fail "site path already exists: ${site_path}"
    studio site create --name "${site_name}" --path "${site_path}" \
      --wp latest --php 8.3 --start --skip-browser --skip-log-details
  fi

  [[ -d "${site_path}/wp-content/plugins" && -d "${site_path}/wp-content/themes" ]] \
    || fail "target does not look like a WordPress site: ${site_path} (use --create-site?)"

  local updated
  updated="$(jq \
    --arg label "${label}" \
    --arg site_path "${site_path}" \
    --argjson themes "${themes}" \
    --argjson plugins "${plugins}" \
    --argjson mu_plugins "${mu_plugins}" \
    '.targets = [{
      label: $label,
      site_path: $site_path,
      themes: $themes,
      plugins: $plugins,
      mu_plugins: $mu_plugins
    }] + .targets' "${config_path}")"
  write_config "${config_path}" "${updated}"

  bash "${SCRIPT_DIR}/wp-code-sync.sh" sync --config "${config_path}" --target "${label}"

  install_watcher "${label}" "${config_path}" "${interval}"

  echo "Target '${label}' ready:"
  echo "  site:    ${site_path}"
  echo "  watcher: $(launchd_label_for "${label}") (interval ${interval}s)"
}

cmd_remove() {
  local label="$1"; shift
  local config_path="${DEFAULT_CONFIG_PATH}" delete_site=0 assume_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-site) delete_site=1; shift ;;
      --yes) assume_yes=1; shift ;;
      --config) config_path="$2"; shift 2 ;;
      *) fail "unknown option for remove: $1" ;;
    esac
  done

  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  target_exists "${config_path}" "${label}" || fail "no such target: ${label}"

  local site_path
  site_path="$(target_site_path "${config_path}" "${label}")"

  remove_watcher "${label}"

  local updated
  updated="$(jq --arg label "${label}" '.targets = [.targets[] | select(.label != $label)]' "${config_path}")"
  write_config "${config_path}" "${updated}"

  echo "Target '${label}' removed (watcher unloaded, config entry deleted)."

  if [[ "${delete_site}" -eq 1 ]]; then
    require_tool studio
    if [[ "${assume_yes}" -ne 1 ]]; then
      printf "Delete the Studio site AND ALL ITS FILES at %s? [y/N] " "${site_path}"
      read -r reply
      [[ "${reply}" == "y" || "${reply}" == "Y" ]] || { echo "Site kept at ${site_path}."; return 0; }
    fi
    studio site delete --path "${site_path}" --files
    echo "Studio site deleted: ${site_path}"
  else
    echo "Site kept at ${site_path}."
  fi
}

cmd_list() {
  local config_path="${DEFAULT_CONFIG_PATH}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config_path="$2"; shift 2 ;;
      *) fail "unknown option for list: $1" ;;
    esac
  done

  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"

  local label state
  while IFS= read -r label; do
    if watcher_loaded "${label}"; then
      state="watching"
    else
      state="no watcher"
    fi
    printf '%-32s %-12s %s\n' "${label}" "${state}" "$(target_site_path "${config_path}" "${label}")"
  done < <(jq -r '.targets[].label' "${config_path}")
}

main() {
  require_tool jq
  require_tool launchctl

  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  case "${command}" in
    add)
      [[ $# -ge 1 ]] || fail "add requires a <label>"
      local label="$1"; shift
      cmd_add "${label}" "$@"
      ;;
    remove)
      [[ $# -ge 1 ]] || fail "remove requires a <label>"
      local label="$1"; shift
      cmd_remove "${label}" "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      fail "unknown command: ${command}"
      ;;
  esac
}

main "$@"

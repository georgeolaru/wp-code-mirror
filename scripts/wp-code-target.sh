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

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-target.sh add <label> [options]
      --site-path <path>     Target site root (default: ~/Studio/<label>)
      --site-name <name>     Studio site display name (default: "0 <label>" — the digit
                             prefix sorts smoke sites to the top of the Studio app list)
      --themes <a,b>         Comma-separated theme dirs to mirror
      --plugins <a,b>        Comma-separated plugin dirs to mirror
      --mu-plugins <a,b>     Comma-separated mu-plugin entries to mirror
      --create-site          Create the WordPress Studio site first (studio CLI)
      --no-open              Skip auto-opening WP Admin after creating the site
      --interval <seconds>   Watcher base interval (default: 15; idle backoff reaches 300)
      --config <path>        Config file (default: uploads/wp-code-mirror/config/...)

  bash scripts/wp-code-target.sh remove <label> [options]
      --delete-site          Also delete the Studio site AND ITS FILES (asks unless --yes)
      --yes                  Skip the --delete-site confirmation prompt
      --config <path>        Config file

  bash scripts/wp-code-target.sh open <label> [--config <path>]
      Open the target's wp-admin in the browser, auto-logged-in.

  bash scripts/wp-code-target.sh rewatch <label>
      Regenerate + reload the target's launchd watcher (e.g. after script changes).

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
  bash "${SCRIPT_DIR}/wp-code-sync-service.sh" status --target "$1" --json 2>/dev/null \
    | jq -e '.running == true' >/dev/null 2>&1
}

install_watcher() {
  local label="$1" config_path="$2" interval="$3"
  bash "${SCRIPT_DIR}/wp-code-sync-service.sh" install \
    --config "${config_path}" \
    --runtime-dir "${DEFAULT_STORAGE_ROOT}/tmp" \
    --target "${label}" \
    --interval "${interval}" >/dev/null
}

remove_watcher() {
  local label="$1"
  bash "${SCRIPT_DIR}/wp-code-sync-service.sh" uninstall \
    --runtime-dir "${DEFAULT_STORAGE_ROOT}/tmp" \
    --target "${label}" >/dev/null
}

csv_to_json_array() {
  local csv="${1:-}"
  if [[ -z "${csv}" ]]; then
    printf '[]\n'
    return
  fi
  printf '%s\n' "${csv}" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

# Best-effort: open wp-admin in the browser, auto-logged-in via a wp-cli-login magic link
# (the Studio app's one-click login is not exposed through the CLI). Falls back to the plain
# wp-admin URL, and never fails the add flow.
open_wp_admin() {
  local site_path="$1"
  command -v open >/dev/null 2>&1 || return 0

  local pkgs=""
  pkgs="$(studio wp package list --format=csv --path "${site_path}" 2>/dev/null </dev/null || true)"
  if [[ "${pkgs}" != *"wp-cli-login-command"* ]]; then
    studio wp package install aaemnnosttv/wp-cli-login-command --path "${site_path}" </dev/null || true
  fi
  studio wp login install --activate --yes --path "${site_path}" </dev/null >/dev/null 2>&1 \
    || studio wp plugin activate wp-cli-login-server --path "${site_path}" </dev/null >/dev/null 2>&1 \
    || true

  local url=""
  url="$(studio wp login create admin --url-only --path "${site_path}" 2>/dev/null </dev/null || true)"
  if [[ -z "${url}" ]]; then
    local home=""
    home="$(studio wp option get home --path "${site_path}" 2>/dev/null </dev/null || true)"
    [[ -n "${home}" ]] && url="${home}/wp-admin/"
  fi

  if [[ -n "${url}" ]]; then
    echo "Opening WP Admin: ${url}"
    open "${url}" || true
  fi
}

cmd_add() {
  local label="$1"; shift
  local config_path="${DEFAULT_CONFIG_PATH}" site_path="" site_name="" themes_csv="" plugins_csv="" mu_csv="" create_site=0 interval=15 open_admin=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site-path) site_path="$2"; shift 2 ;;
      --site-name) site_name="$2"; shift 2 ;;
      --themes) themes_csv="$2"; shift 2 ;;
      --plugins) plugins_csv="$2"; shift 2 ;;
      --mu-plugins) mu_csv="$2"; shift 2 ;;
      --create-site) create_site=1; shift ;;
      --no-open) open_admin=0; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --config) config_path="$2"; shift 2 ;;
      *) fail "unknown option for add: $1" ;;
    esac
  done

  [[ "${label}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "label must be kebab-case (got: ${label})"
  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  target_exists "${config_path}" "${label}" && fail "target already exists: ${label}"

  site_path="${site_path:-${HOME}/Studio/${label}}"
  # Digit prefix: alphabetical site lists sort digits before letters, so disposable smoke
  # sites cluster at the top of the Studio app instead of scattering among real sites.
  site_name="${site_name:-0 ${label}}"

  local themes plugins mu_plugins
  themes="$(csv_to_json_array "${themes_csv}")"
  plugins="$(csv_to_json_array "${plugins_csv}")"
  mu_plugins="$(csv_to_json_array "${mu_csv}")"
  [[ "$(printf '%s%s%s' "${themes}" "${plugins}" "${mu_plugins}")" != "[][][]" ]] \
    || fail "nothing to mirror: pass at least one of --themes / --plugins / --mu-plugins"

  if [[ "${create_site}" -eq 1 ]]; then
    require_tool studio
    [[ -d "${site_path}" ]] && fail "site path already exists: ${site_path}"
    # Fully non-interactive: admin username/email pinned to Studio's defaults (password stays
    # auto-generated — argv passwords leak via ps; use Studio's one-click admin login), and
    # stdin from /dev/null EOFs any remaining TTY prompt (custom domain, future additions).
    studio site create --name "${site_name}" --path "${site_path}" \
      --wp latest --php 8.3 --start --skip-browser --skip-log-details \
      --admin-username admin --admin-email admin@localhost.com </dev/null
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
      active: true,
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

  if [[ "${create_site}" -eq 1 && "${open_admin}" -eq 1 ]]; then
    open_wp_admin "${site_path}"
  fi
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
    # Non-interactive for the same reason as create; the destructive confirm already happened
    # above (or --yes was passed). Tolerant: a missing or unregistered site must not abort a
    # batch removal — the target/watcher cleanup above is already done.
    if [[ -d "${site_path}" ]]; then
      if studio site delete --path "${site_path}" --files </dev/null; then
        echo "Studio site deleted: ${site_path}"
      else
        echo "Warning: studio could not delete ${site_path} — remove it manually." >&2
      fi
    else
      echo "Site path already gone: ${site_path}"
    fi
  else
    echo "Site kept at ${site_path}."
  fi
}

cmd_open() {
  local label="$1"; shift
  local config_path="${DEFAULT_CONFIG_PATH}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config_path="$2"; shift 2 ;;
      *) fail "unknown option for open: $1" ;;
    esac
  done

  [[ -f "${config_path}" ]] || fail "config file not found: ${config_path}"
  target_exists "${config_path}" "${label}" || fail "no such target: ${label}"

  open_wp_admin "$(target_site_path "${config_path}" "${label}")"
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

  local target label active state
  while IFS= read -r target; do
    label="$(jq -r '.label' <<<"${target}")"
    active="$(jq -r 'if has("active") then .active else true end' <<<"${target}")"
    if [[ "${active}" != "true" ]]; then
      state="inactive"
    elif watcher_loaded "${label}"; then
      state="watching"
    else
      state="no watcher"
    fi
    printf '%-32s %-12s %s\n' "${label}" "${state}" "$(target_site_path "${config_path}" "${label}")"
  done < <(jq -c '.targets[]' "${config_path}")
}

main() {
  require_tool jq

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
    open)
      [[ $# -ge 1 ]] || fail "open requires a <label>"
      local label="$1"; shift
      cmd_open "${label}" "$@"
      ;;
    rewatch)
      [[ $# -ge 1 ]] || fail "rewatch requires a <label>"
      local label="$1"; shift
      target_exists "${DEFAULT_CONFIG_PATH}" "${label}" || fail "no such target: ${label}"
      install_watcher "${label}" "${DEFAULT_CONFIG_PATH}" 15
      echo "Watcher regenerated: $(launchd_label_for "${label}")"
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

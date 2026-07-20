#!/usr/bin/env bash

# Interactive menu over wp-code-target.sh / wp-code-sync.sh — for humans who don't want to
# remember flags. Every action prints the exact underlying command before running it, so the
# menu doubles as a copy/paste cheat sheet.

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

CONFIG_PATH="$(detect_default_storage_root)/config/wp-code-mirror.config.json"
TMP_DIR="$(detect_default_storage_root)/tmp"
TARGET_SH="${SCRIPT_DIR}/wp-code-target.sh"
SYNC_SH="${SCRIPT_DIR}/wp-code-sync.sh"

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim() { printf '\033[2m%s\033[0m' "$1"; }

show_command() {
  echo
  printf '%s %s\n' "$(dim '$')" "$(bold "$*")"
}

run_shown() {
  show_command "$@"
  echo
  "$@"
}

pause() {
  echo
  read -r -p "Press Enter to continue… " _
}

labels() {
  jq -r '.targets[].label' "${CONFIG_PATH}"
}

pick_target() {
  # Prints the chosen label on stdout; empty on cancel. Menu goes to stderr so callers can capture.
  local -a all=()
  while IFS= read -r l; do all+=("$l"); done < <(labels)
  [[ ${#all[@]} -gt 0 ]] || { echo "No targets configured." >&2; return 0; }

  local i
  for i in "${!all[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${all[$i]}" >&2
  done
  printf '   0) cancel\n' >&2

  local choice
  read -r -p "Pick a target: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] || return 0
  [[ "${choice}" -ge 1 && "${choice}" -le ${#all[@]} ]] || return 0
  printf '%s\n' "${all[$((choice - 1))]}"
}

do_new_site() {
  echo
  echo "$(bold 'New mirrored smoke site')"
  local label
  read -r -p "Label (kebab-case, becomes ~/Studio/<label>): " label
  [[ -n "${label}" ]] || { echo "Cancelled."; return 0; }

  echo
  echo "Which stack should it mirror?"
  echo "  1) Free LT stack        $(dim 'anima-lt + pixelgrade-assistant, style-manager, nova-blocks')"
  echo "  2) LT stack + Plus      $(dim 'free stack + pixelgrade-plus, pixelgrade-devmode')"
  echo "  3) Custom               $(dim 'type your own theme/plugin lists')"
  local stack themes plugins
  read -r -p "Stack [1]: " stack
  case "${stack:-1}" in
    1) themes="anima-lt"; plugins="pixelgrade-assistant,style-manager,nova-blocks" ;;
    2) themes="anima-lt"; plugins="pixelgrade-assistant,style-manager,nova-blocks,pixelgrade-plus,pixelgrade-devmode" ;;
    3)
      read -r -p "Themes (comma-separated, empty for none): " themes
      read -r -p "Plugins (comma-separated, empty for none): " plugins
      ;;
    *) echo "Cancelled."; return 0 ;;
  esac

  local create="--create-site"
  local reply
  read -r -p "Create a fresh Studio site at ~/Studio/${label}? [Y/n] " reply
  [[ "${reply}" == "n" || "${reply}" == "N" ]] && create=""

  local -a cmd=(bash "${TARGET_SH}" add "${label}")
  [[ -n "${create}" ]] && cmd+=("${create}")
  [[ -n "${themes}" ]] && cmd+=(--themes "${themes}")
  [[ -n "${plugins}" ]] && cmd+=(--plugins "${plugins}")

  run_shown "${cmd[@]}"
  pause
}

do_remove() {
  echo
  echo "$(bold 'Remove a target')"
  local label
  label="$(pick_target)"
  [[ -n "${label}" ]] || { echo "Cancelled."; return 0; }

  local reply site_flags=()
  read -r -p "Also DELETE the Studio site and its files? [y/N] " reply
  if [[ "${reply}" == "y" || "${reply}" == "Y" ]]; then
    site_flags=(--delete-site --yes)
  fi

  run_shown bash "${TARGET_SH}" remove "${label}" ${site_flags[@]+"${site_flags[@]}"}
  pause
}

do_sync_now() {
  echo
  echo "$(bold 'One-shot sync')"
  local label
  label="$(pick_target)"
  [[ -n "${label}" ]] || { echo "Cancelled."; return 0; }

  run_shown bash "${SYNC_SH}" sync --config "${CONFIG_PATH}" --target "${label}"
  pause
}

do_tail_log() {
  echo
  echo "$(bold 'Recent watcher activity')"
  local label
  label="$(pick_target)"
  [[ -n "${label}" ]] || { echo "Cancelled."; return 0; }

  local log="${TMP_DIR}/wp-code-mirror-${label}.error.log"
  show_command tail -n 20 "${log}"
  echo
  if [[ -f "${log}" ]]; then
    tail -n 20 "${log}"
  else
    echo "(no log yet at ${log})"
  fi
  pause
}

do_cheatsheet() {
  echo
  echo "$(bold 'Copy/paste cheat sheet')  $(dim "(run from ${ROOT_DIR})")"
  cat <<EOF

  # List every target + watcher state
  bash scripts/wp-code-target.sh list

  # New mirrored Studio smoke site with the free LT stack
  bash scripts/wp-code-target.sh add my-smoke --create-site \\
    --themes anima-lt --plugins pixelgrade-assistant,style-manager,nova-blocks

  # Add an EXISTING site as a target (no site creation)
  bash scripts/wp-code-target.sh add my-smoke --site-path ~/Studio/my-smoke \\
    --plugins pixelgrade-assistant

  # Remove a target (keeps the site) / remove and delete the site
  bash scripts/wp-code-target.sh remove my-smoke
  bash scripts/wp-code-target.sh remove my-smoke --delete-site

  # One-shot sync / live status
  bash scripts/wp-code-sync.sh sync --target my-smoke
  bash scripts/wp-code-sync.sh status
EOF
  pause
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    echo "$(bold 'wp-code-mirror')  $(dim "${CONFIG_PATH}")"
    echo
    bash "${TARGET_SH}" list --config "${CONFIG_PATH}" | sed 's/^/  /'
    echo
    echo "  1) New mirrored smoke site"
    echo "  2) Remove a target"
    echo "  3) Sync a target now"
    echo "  4) Show a watcher's recent activity"
    echo "  5) Copy/paste cheat sheet"
    echo "  q) Quit"
    echo
    local choice
    read -r -p "> " choice
    case "${choice}" in
      1) do_new_site ;;
      2) do_remove ;;
      3) do_sync_now ;;
      4) do_tail_log ;;
      5) do_cheatsheet ;;
      q|Q|0) echo "Bye."; exit 0 ;;
      *) ;;
    esac
  done
}

command -v jq >/dev/null 2>&1 || { echo "Error: missing required tool: jq" >&2; exit 1; }
[[ -f "${CONFIG_PATH}" ]] || { echo "Error: config file not found: ${CONFIG_PATH}" >&2; exit 1; }

main_menu

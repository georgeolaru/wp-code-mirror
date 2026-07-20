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

CONFIG_PATH="${WP_CODE_MIRROR_CONFIG:-$(detect_default_storage_root)/config/wp-code-mirror.config.json}"
TMP_DIR="$(detect_default_storage_root)/tmp"
TARGET_SH="${SCRIPT_DIR}/wp-code-target.sh"
SYNC_SH="${SCRIPT_DIR}/wp-code-sync.sh"
DEV_SITE_SH="${SCRIPT_DIR}/wp-code-dev-site.sh"

command_usage() {
  cat <<'EOF'
Usage:
  pxgmirror
  pxgmirror add <label> [wp-code-target add options]
  pxgmirror remove <label> [wp-code-target remove options]
  pxgmirror list [wp-code-target list options]
  pxgmirror sync [wp-code-sync sync options]
  pxgmirror status [wp-code-sync status options]
  pxgmirror watch [wp-code-sync watch options]
  pxgmirror help

Without a command, pxgmirror opens the interactive menu.
EOF
}

dispatch_command() {
  local command_name="$1"
  shift

  case "${command_name}" in
    add|remove|list)
      exec bash "${TARGET_SH}" "${command_name}" "$@"
      ;;
    sync|status|watch)
      exec bash "${SYNC_SH}" "${command_name}" "$@"
      ;;
    help|-h|--help)
      command_usage
      ;;
    *)
      command_usage >&2
      echo "Error: unknown pxgmirror command: ${command_name}" >&2
      return 1
      ;;
  esac
}

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim() { printf '\033[2m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
cyan() { printf '\033[36m%s\033[0m' "$1"; }

watcher_loaded() {
  launchctl print "gui/$(id -u)/com.wp-code-mirror.sync.$1" >/dev/null 2>&1
}

# Truncate to N chars with a real ellipsis, ANSI-free input only.
fit() {
  local s="$1" n="$2"
  if [[ ${#s} -gt ${n} ]]; then
    printf '%s…' "${s:0:$((n - 1))}"
  else
    printf '%s' "${s}"
  fi
}

tilde() {
  local t='~'
  printf '%s' "${1/#${HOME}/${t}}"
}

# Single-keypress read (no Enter needed). Bash 3.2-safe. Echoes the missing newline.
read_key() {
  local __var="$1" __prompt="$2" __reply=""
  read -r -n 1 -p "${__prompt}" __reply || true
  [[ -n "${__reply}" ]] && echo
  printf -v "${__var}" '%s' "${__reply}"
}

show_command() {
  echo
  printf '%s %s\n' "$(dim '$')" "$(bold "$*")"
}

run_shown() {
  show_command "$@"
  echo
  "$@"
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

# Claude-questions-style checkbox picker: arrows/j/k move, space toggles, a all, n none,
# Enter confirms, q or bare ESC cancels. Selected labels print to stdout, one per line;
# all UI goes to stderr. Globals because bash 3.2 cannot pass arrays.
MP_CURSOR=0
MP_DRAWN=0

mp_draw() {
  local j box line
  if [[ ${MP_DRAWN} -eq 1 ]]; then
    printf '\033[%dA' "${#MP_ITEMS[@]}" >&2
  fi
  for j in "${!MP_ITEMS[@]}"; do
    if [[ "${MP_CHECKED[$j]}" -eq 1 ]]; then box="[x]"; else box="[ ]"; fi
    printf '\033[2K' >&2
    if [[ ${j} -eq ${MP_CURSOR} ]]; then
      printf '  %s %s %s\n' "$(cyan '❯')" "${box}" "$(bold "${MP_ITEMS[$j]}")" >&2
    else
      printf '    %s %s\n' "${box}" "${MP_ITEMS[$j]}" >&2
    fi
  done
  MP_DRAWN=1
}

multi_pick() {
  MP_ITEMS=()
  MP_CHECKED=()
  MP_CURSOR=0
  MP_DRAWN=0
  local l key rest j count
  while IFS= read -r l; do MP_ITEMS+=("$l"); MP_CHECKED+=(0); done < <(labels)
  count=${#MP_ITEMS[@]}
  [[ ${count} -gt 0 ]] || { echo "No targets configured." >&2; return 0; }

  printf '  %s\n' "$(dim '↑↓ move · space select · a all · n none · enter confirm · q cancel')" >&2
  mp_draw

  while true; do
    IFS= read -rsn1 key || return 0
    case "${key}" in
      $'\x1b')
        rest=""
        read -rsn2 -t 1 rest || true
        case "${rest}" in
          '[A') MP_CURSOR=$(( (MP_CURSOR + count - 1) % count )) ;;
          '[B') MP_CURSOR=$(( (MP_CURSOR + 1) % count )) ;;
          '') return 0 ;;
        esac
        ;;
      k) MP_CURSOR=$(( (MP_CURSOR + count - 1) % count )) ;;
      j) MP_CURSOR=$(( (MP_CURSOR + 1) % count )) ;;
      ' ')
        if [[ "${MP_CHECKED[$MP_CURSOR]}" -eq 1 ]]; then
          MP_CHECKED[$MP_CURSOR]=0
        else
          MP_CHECKED[$MP_CURSOR]=1
        fi
        ;;
      a) for j in "${!MP_CHECKED[@]}"; do MP_CHECKED[$j]=1; done ;;
      n) for j in "${!MP_CHECKED[@]}"; do MP_CHECKED[$j]=0; done ;;
      q) return 0 ;;
      '') break ;;
    esac
    mp_draw
  done

  for j in "${!MP_ITEMS[@]}"; do
    [[ "${MP_CHECKED[$j]}" -eq 1 ]] && printf '%s\n' "${MP_ITEMS[$j]}"
  done
  return 0
}

default_label() {
  # smoke-<MMDD>, auto-incremented until it collides with neither a config target nor a
  # ~/Studio directory.
  local base candidate n=1 existing
  base="smoke-$(date +%m%d)"
  candidate="${base}"
  existing="$(labels)"
  while grep -Fxq "${candidate}" <<< "${existing}" || [[ -d "${HOME}/Studio/${candidate}" ]]; do
    n=$((n + 1))
    candidate="${base}-${n}"
  done
  printf '%s\n' "${candidate}"
}

do_new_site() {
  echo
  echo "$(bold 'New mirrored smoke site')"
  local label suggested
  suggested="$(default_label)"
  read -r -p "Label [${suggested}]: " label
  label="${label:-${suggested}}"

  echo
  echo "Which stack should it mirror?"
  echo "  1) Free LT stack        $(dim 'anima-lt + pixelgrade-assistant, style-manager, nova-blocks')"
  echo "  2) LT stack + Plus      $(dim 'free stack + pixelgrade-plus, pixelgrade-devmode — nothing activated')"
  echo "  3) Plus dev site        $(dim 'stack activated + licensed + WooCommerce + optional starter, headless')"
  echo "  4) Custom               $(dim 'type your own theme/plugin lists')"
  local stack themes plugins provision=0 starter=""
  read_key stack "Stack [1]: "
  case "${stack:-1}" in
    1) themes="anima-lt"; plugins="pixelgrade-assistant,style-manager,nova-blocks" ;;
    2) themes="anima-lt"; plugins="pixelgrade-assistant,style-manager,nova-blocks,pixelgrade-plus,pixelgrade-devmode" ;;
    3)
      themes="anima-lt"; plugins="pixelgrade-assistant,style-manager,nova-blocks,pixelgrade-plus,pixelgrade-devmode"
      provision=1
      echo
      echo "Load a starter site automatically? $(dim 'full import, only into an empty site')"
      echo "  1) Rosa LT   2) Mies LT   3) Felt LT   4) Julia LT   5) Pile LT   0) none"
      local pick
      read_key pick "Starter [0]: "
      case "${pick:-0}" in
        1) starter="rosa-lt" ;;
        2) starter="mies-lt" ;;
        3) starter="felt-lt" ;;
        4) starter="julia-lt" ;;
        5) starter="pile-lt" ;;
        *) starter="" ;;
      esac
      ;;
    4)
      read -r -p "Themes (comma-separated, empty for none): " themes
      read -r -p "Plugins (comma-separated, empty for none): " plugins
      ;;
    *) echo "Cancelled."; return 0 ;;
  esac

  # No question: a fresh Studio site is created unless ~/Studio/<label> already exists,
  # in which case the existing site is adopted as the target.
  local -a cmd=(bash "${TARGET_SH}" add "${label}" --config "${CONFIG_PATH}")
  if [[ ! -d "${HOME}/Studio/${label}" ]]; then
    cmd+=(--create-site)
  fi
  [[ ${provision} -eq 1 ]] && cmd+=(--no-open)
  [[ -n "${themes}" ]] && cmd+=(--themes "${themes}")
  [[ -n "${plugins}" ]] && cmd+=(--plugins "${plugins}")

  run_shown "${cmd[@]}"

  if [[ ${provision} -eq 1 ]]; then
    local -a prov=(bash "${DEV_SITE_SH}" provision "${HOME}/Studio/${label}" --woo)
    [[ -n "${starter}" ]] && prov+=(--starter "${starter}")
    run_shown "${prov[@]}"
    run_shown bash "${TARGET_SH}" open "${label}" --config "${CONFIG_PATH}"
  fi
}

do_remove() {
  echo
  # Selecting + Enter IS the confirmation: removal deletes the target, its watcher, AND the
  # Studio site with its files. The header says so; there is no follow-up question.
  echo "$(bold 'Remove targets')  $(dim 'deletes the Studio site and its files too')"
  local -a picked=()
  local l
  while IFS= read -r l; do [[ -n "${l}" ]] && picked+=("${l}"); done < <(multi_pick)
  [[ ${#picked[@]:-0} -gt 0 ]] || { echo "Cancelled."; return 0; }

  local label
  for label in "${picked[@]}"; do
    run_shown bash "${TARGET_SH}" remove "${label}" --config "${CONFIG_PATH}" --delete-site --yes
  done
}

do_sync_now() {
  echo
  echo "$(bold 'One-shot sync')"
  local label
  label="$(pick_target)"
  [[ -n "${label}" ]] || { echo "Cancelled."; return 0; }

  run_shown bash "${SYNC_SH}" sync --config "${CONFIG_PATH}" --target "${label}"
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
}

render_header() {
  local total watching_count source_short inner line
  total="$(jq -r '.targets | length' "${CONFIG_PATH}")"
  watching_count=0
  local l
  while IFS= read -r l; do
    watcher_loaded "${l}" && watching_count=$((watching_count + 1))
  done < <(labels)
  source_short="$(tilde "$(jq -r '.source_site' "${CONFIG_PATH}")")"

  inner=" wp-code-mirror · ${total} targets · ${watching_count} watching · ${source_short} "
  line="$(printf '%*s' "${#inner}" '' | sed 's/ /─/g')"
  printf '╭%s╮\n' "${line}"
  printf '│%s│\n' "$(bold "${inner}")"
  printf '╰%s╯\n' "${line}"
}

plural() {
  [[ "$1" == "1" ]] || printf 's'
}

render_targets() {
  local label site_path themes plugins mus dot contents
  while IFS=$'\t' read -r label site_path themes plugins mus; do
    if watcher_loaded "${label}"; then
      dot="$(green '●')"
    else
      dot="$(dim '○')"
    fi
    contents=""
    if [[ "${themes}" != "0" ]]; then
      contents="${themes} theme$(plural "${themes}")"
    fi
    if [[ "${plugins}" != "0" ]]; then
      if [[ -n "${contents}" ]]; then contents="${contents} · "; fi
      contents="${contents}${plugins} plugin$(plural "${plugins}")"
    fi
    if [[ "${mus}" != "0" ]]; then
      if [[ -n "${contents}" ]]; then contents="${contents} · "; fi
      contents="${contents}${mus} mu"
    fi
    printf '  %b %-28s %-34s %b\n' \
      "${dot}" \
      "$(fit "${label}" 28)" \
      "$(fit "$(tilde "${site_path}")" 34)" \
      "$(dim "${contents}")"
  done < <(jq -r '.targets[] | [.label, .site_path, (.themes | length), (.plugins | length), (.mu_plugins | length)] | @tsv' "${CONFIG_PATH}")
}

main_menu() {
  clear 2>/dev/null || true
  while true; do
    echo
    render_header
    echo
    render_targets
    echo
    printf '  %b New smoke site   %b Remove   %b Sync   %b Watcher log   %b Cheat sheet   %b Quit\n' \
      "$(cyan '1')" "$(cyan '2')" "$(cyan '3')" "$(cyan '4')" "$(cyan '5')" "$(cyan 'q')"
    echo
    local choice
    read_key choice "> "
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

if [[ "$#" -gt 0 ]]; then
  dispatch_command "$@"
  exit $?
fi

command -v jq >/dev/null 2>&1 || { echo "Error: missing required tool: jq" >&2; exit 1; }
[[ -f "${CONFIG_PATH}" ]] || { echo "Error: config file not found: ${CONFIG_PATH}" >&2; exit 1; }
main_menu

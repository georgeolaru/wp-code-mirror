#!/usr/bin/env bash

set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/wp-code-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wp-code-sync-performance.XXXXXX")"
FAILURES=0

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_jq() {
  local json="$1"
  local expression="$2"
  local message="$3"

  printf '%s' "${json}" | jq -e "${expression}" >/dev/null || fail "${message} (${expression})"
}

run_test() {
  local name="$1"
  local function_name="$2"

  if "${function_name}"; then
    printf 'PASS: %s\n' "${name}"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

make_site() {
  local site_path="$1"
  mkdir -p "${site_path}/wp-content/themes" "${site_path}/wp-content/plugins"
}

make_three_component_fixture() {
  local fixture_root="$1"
  local source_site="${fixture_root}/source"
  local target_site="${fixture_root}/target"

  make_site "${source_site}"
  make_site "${target_site}"

  local slug
  for slug in alpha beta gamma; do
    mkdir -p "${source_site}/wp-content/plugins/${slug}" "${target_site}/wp-content/plugins/${slug}"
    printf '%s-v1\n' "${slug}" >"${source_site}/wp-content/plugins/${slug}/file.php"
    cp -p "${source_site}/wp-content/plugins/${slug}/file.php" "${target_site}/wp-content/plugins/${slug}/file.php"
    /usr/bin/rsync -a --delete "${source_site}/wp-content/plugins/${slug}/" "${target_site}/wp-content/plugins/${slug}/"
  done

  jq -n \
    --arg source "${source_site}" \
    --arg target "${target_site}" \
    '{
      source_site: $source,
      targets: [{
        label: "bench",
        site_path: $target,
        active: true,
        themes: [],
        plugins: ["alpha", "beta", "gamma"],
        mu_plugins: []
      }],
      rsync_excludes: ["*.map", "*.phar"]
    }' >"${fixture_root}/config.json"
}

make_counting_rsync() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" != "--server" ]]; then
  printf '%q ' "$@" >>"${WPCM_TEST_RSYNC_LOG}"
  printf '\n' >>"${WPCM_TEST_RSYNC_LOG}"
fi
exec /usr/bin/rsync "$@"
RSYNC
  chmod +x "${bin_dir}/rsync"
}

count_dry_runs() {
  local log_path="$1"
  grep -c -- '--dry-run' "${log_path}" 2>/dev/null || true
}

count_real_syncs() {
  local log_path="$1"
  awk '!/--dry-run/ { count++ } END { print count + 0 }' "${log_path}"
}

test_warnings_are_not_changes_or_repeat_sync_triggers() {
  local fixture="${TEST_ROOT}/warning"
  make_three_component_fixture "${fixture}"

  local source_alpha="${fixture}/source/wp-content/plugins/alpha"
  local target_alpha="${fixture}/target/wp-content/plugins/alpha"
  mkdir -p "${target_alpha}/stale"
  printf 'protected\n' >"${target_alpha}/stale/tool.phar"

  local status_json
  status_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1

  assert_jq "${status_json}" '.overall_state == "CLEAN"' 'warning-only status must remain CLEAN' || return 1
  assert_jq "${status_json}" '.targets[0].items[] | select(.slug == "alpha") | (.pending == false and .warning_count >= 1 and .error_count == 0)' 'warning must be represented separately' || return 1
  assert_jq "${status_json}" '[.targets[0].items[].warnings | length] | max <= 10' 'warning samples must be capped' || return 1

  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" \
    /bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/config.json" --target bench --json >/dev/null || return 1

  assert_equals "$(count_real_syncs "${rsync_log}")" "0" 'warning-only analysis must not trigger a sync' || return 1
}

test_rsync_errors_are_explicit_without_full_sync() {
  local fixture="${TEST_ROOT}/error"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/rsync" <<'RSYNC'
#!/usr/bin/env bash
printf 'rsync: connection unexpectedly closed\n'
exit 12
RSYNC
  chmod +x "${bin_dir}/rsync"

  local status_json
  status_json="$(PATH="${bin_dir}:${PATH}" /bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1

  assert_jq "${status_json}" '.overall_state == "ERROR"' 'rsync failure must make overall status ERROR' || return 1
  assert_jq "${status_json}" '.targets[0].items[0] | (.state == "ERROR" and .error_count >= 1 and (.errors | length) >= 1)' 'rsync error must be explicit and compact' || return 1

  local sync_json sync_rc
  sync_json="$(PATH="${bin_dir}:${PATH}" /bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/config.json" --target bench --json)"
  sync_rc=$?
  assert_equals "${sync_rc}" "1" 'sync command must fail when its resulting status is ERROR' || return 1
  assert_jq "${sync_json}" '.overall_state == "ERROR"' 'failed sync must still emit explicit JSON status' || return 1
}

test_vanished_source_files_are_retried_without_error_or_full_sync() {
  local fixture="${TEST_ROOT}/vanished"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/rsync" <<'RSYNC'
#!/usr/bin/env bash
printf 'rsync warning: some files vanished before they could be transferred\n'
exit 24
RSYNC
  chmod +x "${bin_dir}/rsync"

  local status_json
  status_json="$(PATH="${bin_dir}:${PATH}" /bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1

  assert_jq "${status_json}" '.overall_state == "PENDING"' 'vanished source files must schedule a later analysis' || return 1
  assert_jq "${status_json}" '.targets[0].items[0] | (.state == "PENDING" and .sync_required == false and .warning_count >= 1 and .error_count == 0)' 'vanished files must not be treated as a real diff or hard error' || return 1
}

test_file_component_rsync_errors_are_captured() {
  local fixture="${TEST_ROOT}/file-error"
  make_three_component_fixture "${fixture}"
  mkdir -p "${fixture}/source/wp-content/mu-plugins" "${fixture}/target/wp-content/mu-plugins"
  printf 'loader\n' >"${fixture}/source/wp-content/mu-plugins/loader.php"
  jq '.targets[0].plugins = [] | .targets[0].mu_plugins = ["loader.php"]' "${fixture}/config.json" >"${fixture}/file-config.json"
  local bin_dir="${fixture}/bin"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/rsync" <<'RSYNC'
#!/usr/bin/env bash
printf 'rsync: file transfer failed\n'
exit 12
RSYNC
  chmod +x "${bin_dir}/rsync"

  local status_json
  status_json="$(PATH="${bin_dir}:${PATH}" /bin/bash "${SCRIPT_PATH}" status --config "${fixture}/file-config.json" --target bench --json)" || return 1
  assert_jq "${status_json}" '.overall_state == "ERROR" and .targets[0].items[0].error_count == 1' 'file rsync failure must be captured as explicit status'
}

test_only_changed_component_is_synchronized() {
  local fixture="${TEST_ROOT}/selective"
  make_three_component_fixture "${fixture}"
  printf 'alpha-version-2-changed\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"

  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  local sync_json
  sync_json="$(PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" \
    /bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/config.json" --target bench --json)" || return 1

  assert_equals "$(count_dry_runs "${rsync_log}")" "3" 'one analysis must scan each component once' || return 1
  assert_equals "$(count_real_syncs "${rsync_log}")" "1" 'only the changed component must be synced' || return 1
  assert_jq "${sync_json}" '.synced_components == ["plugins/alpha"]' 'status must name only the synchronized component' || return 1
  assert_jq "${sync_json}" '.overall_state == "CLEAN"' 'successful selective sync must produce CLEAN status without rescanning' || return 1
  assert_jq "${sync_json}" '.targets[0].items[] | select(.slug == "alpha") | (.changes == [] and .change_count == 0)' 'clean synchronized item must not retain a stale change count' || return 1
  assert_equals "$(<"${fixture}/target/wp-content/plugins/alpha/file.php")" 'alpha-version-2-changed' 'changed component content must be mirrored' || return 1
}

test_component_error_does_not_block_independent_sync() {
  local fixture="${TEST_ROOT}/partial-error"
  make_three_component_fixture "${fixture}"
  printf 'alpha-version-2-changed\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"
  rm -rf "${fixture}/source/wp-content/plugins/beta"

  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  local sync_json sync_rc
  sync_json="$(PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" \
    /bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/config.json" --target bench --json)"
  sync_rc=$?

  assert_equals "${sync_rc}" "1" 'partial sync must return failure while any component remains ERROR' || return 1
  assert_equals "$(count_real_syncs "${rsync_log}")" "1" 'an unrelated component error must not block a valid selective sync' || return 1
  assert_jq "${sync_json}" '.overall_state == "ERROR" and .synced_components == ["plugins/alpha"]' 'partial success must preserve the independent error' || return 1
  assert_equals "$(<"${fixture}/target/wp-content/plugins/alpha/file.php")" 'alpha-version-2-changed' 'valid component must still be mirrored' || return 1
}

test_sync_cleans_temporary_analysis_files() {
  local fixture="${TEST_ROOT}/temporary-files"
  make_three_component_fixture "${fixture}"
  printf 'alpha-version-2-changed\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"
  mkdir -p "${fixture}/tmp" "${fixture}/bin"
  cat >"${fixture}/bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
set -u
path="${WPCM_TEST_MKTEMP_ROOT}/temporary.$$.$RANDOM"
: >"${path}"
printf '%s\n' "${path}" >>"${WPCM_TEST_MKTEMP_LOG}"
printf '%s\n' "${path}"
MKTEMP
  chmod +x "${fixture}/bin/mktemp"

  PATH="${fixture}/bin:${PATH}" WPCM_TEST_MKTEMP_ROOT="${fixture}/tmp" WPCM_TEST_MKTEMP_LOG="${fixture}/allocations.log" /bin/bash "${SCRIPT_PATH}" sync \
    --config "${fixture}/config.json" --target bench --json >/dev/null || return 1

  assert_equals "$(find "${fixture}/tmp" -type f | wc -l | tr -d ' ')" "0" 'sync must remove all of its temporary analysis files'
}

test_clean_watch_cycle_scans_each_tree_once() {
  local fixture="${TEST_ROOT}/single-scan"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" \
    /bin/bash "${SCRIPT_PATH}" watch --config "${fixture}/config.json" --target bench \
      --interval 0.01 --max-interval 0.02 --debounce 0 --max-cycles 1 \
      --status-file "${fixture}/status.json" >/dev/null || return 1

  assert_equals "$(count_dry_runs "${rsync_log}")" "3" 'clean cycle must not rescan for status' || return 1
  assert_jq "$(<"${fixture}/status.json")" '.overall_state == "CLEAN"' 'clean cycle must write reused analysis status' || return 1
  assert_jq "$(<"${fixture}/status.json")" 'has("last_sync_at") | not' 'clean cycle must not claim a synchronization occurred' || return 1
}

test_analysis_does_not_create_missing_component_directories() {
  local fixture="${TEST_ROOT}/read-only-analysis"
  make_three_component_fixture "${fixture}"
  rm -rf "${fixture}/target/wp-content/plugins/gamma"

  local status_json
  status_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1

  assert_jq "${status_json}" '.overall_state == "PENDING"' 'missing component must be reported pending' || return 1
  [[ ! -e "${fixture}/target/wp-content/plugins/gamma" ]] || fail 'dry-run analysis must not create target directories'
}

test_lock_prevents_overlapping_cycles() {
  local fixture="${TEST_ROOT}/overlap"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  local entered_log="${fixture}/entered.log"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/rsync" <<'RSYNC'
#!/usr/bin/env bash
printf 'entered\n' >>"${WPCM_TEST_ENTERED_LOG}"
sleep 1
exit 0
RSYNC
  chmod +x "${bin_dir}/rsync"

  PATH="${bin_dir}:${PATH}" WPCM_TEST_ENTERED_LOG="${entered_log}" \
    /bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json \
      --lock-dir "${fixture}/locks" >"${fixture}/first.json" 2>"${fixture}/first.err" &
  local first_pid=$!

  local attempts=0
  while [[ ! -s "${entered_log}" && "${attempts}" -lt 50 ]]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [[ -s "${entered_log}" ]] || { kill "${first_pid}" 2>/dev/null || true; return 1; }

  local second_rc
  if PATH="${bin_dir}:${PATH}" WPCM_TEST_ENTERED_LOG="${entered_log}" \
    /bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json \
      --lock-dir "${fixture}/locks" >"${fixture}/second.json" 2>"${fixture}/second.err"; then
    second_rc=0
  else
    second_rc=$?
  fi

  wait "${first_pid}" || return 1

  assert_equals "${second_rc}" "75" 'overlapping cycle must return temporary-failure status' || return 1
  assert_equals "$(wc -l <"${entered_log}" | tr -d ' ')" "3" 'second process must not enter rsync analysis' || return 1
}

test_abandoned_lock_is_recovered() {
  local fixture="${TEST_ROOT}/stale-lock"
  make_three_component_fixture "${fixture}"
  mkdir -p "${fixture}/locks/bench.lock"
  printf '999999\n' >"${fixture}/locks/bench.lock/owner"

  local status_json
  status_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json \
    --lock-dir "${fixture}/locks")" || return 1

  assert_jq "${status_json}" '.overall_state == "CLEAN"' 'cycle must continue after stale-lock recovery' || return 1
  [[ ! -d "${fixture}/locks/bench.lock" ]] || fail 'recovered lock must be released after the cycle'
}

test_missing_target_exits_without_restart_loop() {
  local fixture="${TEST_ROOT}/missing"
  make_three_component_fixture "${fixture}"
  jq '.targets[0].site_path = "/definitely/missing/wp-code-mirror-target"' \
    "${fixture}/config.json" >"${fixture}/missing-config.json"

  /bin/bash "${SCRIPT_PATH}" watch --config "${fixture}/missing-config.json" --target bench \
    --interval 0.01 --max-interval 0.02 --debounce 0 --max-cycles 3 \
    --status-file "${fixture}/status.json" --log-file "${fixture}/watch.log" || return 1

  assert_jq "$(<"${fixture}/status.json")" '.overall_state == "MISSING"' 'missing target status must be MISSING' || return 1
  assert_equals "$(grep -c 'TARGET_MISSING' "${fixture}/watch.log" || true)" "1" 'missing target must be logged once before controlled exit' || return 1
}

test_idle_backoff_reduces_scan_frequency() {
  local fixture="${TEST_ROOT}/backoff"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  local elapsed
  elapsed="$(PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" python3 - \
    "${SCRIPT_PATH}" "${fixture}/config.json" "${fixture}/status.json" <<'PY'
import os
import subprocess
import sys
import time

started = time.monotonic()
subprocess.run([
    "/bin/bash", sys.argv[1], "watch", "--config", sys.argv[2], "--target", "bench",
    "--interval", "0.05", "--max-interval", "0.2", "--debounce", "0",
    "--max-cycles", "4", "--status-file", sys.argv[3],
], check=True, env=os.environ.copy(), stdout=subprocess.DEVNULL)
print(f"{time.monotonic() - started:.3f}")
PY
)" || return 1

  assert_equals "$(count_dry_runs "${rsync_log}")" "12" 'four idle cycles must scan three components once each' || return 1
  awk -v elapsed="${elapsed}" 'BEGIN { exit !(elapsed >= 0.45) }' || fail "idle backoff did not increase waits (elapsed ${elapsed}s)"
}

test_debounce_groups_rapid_file_changes() {
  local fixture="${TEST_ROOT}/debounce"
  make_three_component_fixture "${fixture}"
  local bin_dir="${fixture}/bin"
  local rsync_log="${fixture}/rsync.log"
  make_counting_rsync "${bin_dir}"
  : >"${rsync_log}"

  PATH="${bin_dir}:${PATH}" WPCM_TEST_RSYNC_LOG="${rsync_log}" \
    /bin/bash "${SCRIPT_PATH}" watch --config "${fixture}/config.json" --target bench \
      --interval 0.01 --max-interval 0.02 --debounce 0.3 --max-cycles 1 \
      --status-file "${fixture}/status.json" >/dev/null &
  local watcher_pid=$!

  sleep 0.05
  printf 'alpha-version-2\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"
  sleep 0.05
  printf 'alpha-version-3-expanded\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"
  sleep 0.05
  printf 'alpha-version-4-final\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"

  wait "${watcher_pid}" || return 1

  assert_equals "$(count_real_syncs "${rsync_log}")" "1" 'rapid changes to one component must be grouped into one sync' || return 1
  assert_equals "$(<"${fixture}/target/wp-content/plugins/alpha/file.php")" 'alpha-version-4-final' 'debounced sync must copy final content' || return 1
}

test_logs_rotate_and_remain_concise() {
  local fixture="${TEST_ROOT}/rotation"
  make_three_component_fixture "${fixture}"
  dd if=/dev/zero of="${fixture}/watch.log" bs=2048 count=1 2>/dev/null

  /bin/bash "${SCRIPT_PATH}" watch --config "${fixture}/config.json" --target bench \
    --interval 0.01 --max-interval 0.02 --debounce 0 --max-cycles 1 \
    --status-file "${fixture}/status.json" --log-file "${fixture}/watch.log" \
    --error-log-file "${fixture}/watch.error.log" --log-max-bytes 512 >/dev/null || return 1

  [[ -f "${fixture}/watch.log.1" ]] || fail 'oversized log must be rotated' || return 1
  [[ "$(wc -c <"${fixture}/watch.log")" -le 512 ]] || fail 'active log must stay within configured limit' || return 1
  [[ "$(grep -c 'SYNCED' "${fixture}/watch.log" || true)" -eq 0 ]] || fail 'clean cycles must not emit component SYNCED spam'
}

test_status_aggregation_covers_all_states() {
  local fixture="${TEST_ROOT}/states"
  make_three_component_fixture "${fixture}"

  local clean_json
  clean_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1
  assert_jq "${clean_json}" '.overall_state == "CLEAN"' 'clean status aggregation' || return 1

  printf 'alpha-version-2-changed\n' >"${fixture}/source/wp-content/plugins/alpha/file.php"
  local pending_json
  pending_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/config.json" --target bench --json)" || return 1
  assert_jq "${pending_json}" '.overall_state == "PENDING" and .targets[0].state == "PENDING"' 'pending status aggregation' || return 1

  jq '.targets += [{label:"missing",site_path:"/definitely/missing",active:true,themes:[],plugins:["alpha"],mu_plugins:[]}]' \
    "${fixture}/config.json" >"${fixture}/mixed.json"
  local missing_json
  missing_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/mixed.json" --target missing --json)" || return 1
  assert_jq "${missing_json}" '.overall_state == "MISSING" and .targets[0].state == "MISSING"' 'missing status aggregation' || return 1

  jq '.targets[0].plugins = ["does-not-exist"]' "${fixture}/config.json" >"${fixture}/error.json"
  local error_json
  error_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/error.json" --target bench --json)" || return 1
  assert_jq "${error_json}" '.overall_state == "ERROR" and .targets[0].state == "ERROR"' 'error status aggregation' || return 1
}

test_excludes_match_between_analysis_and_sync() {
  local fixture="${TEST_ROOT}/excludes"
  make_three_component_fixture "${fixture}"
  printf 'ignored\n' >"${fixture}/source/wp-content/plugins/alpha/generated.map"
  mkdir -p "${fixture}/source/wp-content/mu-plugins" "${fixture}/target/wp-content/mu-plugins"
  printf 'ignored loader\n' >"${fixture}/source/wp-content/mu-plugins/ignored.map"
  touch -r "${fixture}/source/wp-content/mu-plugins" "${fixture}/target/wp-content/mu-plugins"
  jq '.targets[0].mu_plugins = ["ignored.map"]' "${fixture}/config.json" >"${fixture}/with-file.json"

  local status_json
  status_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/with-file.json" --target bench --json)" || return 1
  assert_jq "${status_json}" '.overall_state == "CLEAN"' 'excluded file component must not be pending during analysis' || return 1

  local sync_json
  sync_json="$(/bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/with-file.json" --target bench --json)" || return 1

  [[ ! -e "${fixture}/target/wp-content/plugins/alpha/generated.map" ]] || fail 'excluded artifact must not be copied' || return 1
  [[ ! -e "${fixture}/target/wp-content/mu-plugins/ignored.map" ]] || fail 'excluded file component must not be copied' || return 1
  assert_jq "${sync_json}" '.overall_state == "CLEAN"' 'excluded artifact must not remain pending after sync'
}

test_file_component_preserves_archive_metadata() {
  local fixture="${TEST_ROOT}/file-metadata"
  make_three_component_fixture "${fixture}"
  mkdir -p "${fixture}/source/wp-content/mu-plugins" "${fixture}/target/wp-content/mu-plugins"
  printf 'loader\n' >"${fixture}/source/wp-content/mu-plugins/loader.php"
  cp -p "${fixture}/source/wp-content/mu-plugins/loader.php" "${fixture}/target/wp-content/mu-plugins/loader.php"
  chmod 755 "${fixture}/source/wp-content/mu-plugins/loader.php"
  chmod 644 "${fixture}/target/wp-content/mu-plugins/loader.php"
  jq '.targets[0].mu_plugins = ["loader.php"]' "${fixture}/config.json" >"${fixture}/with-loader.json"

  local status_json
  status_json="$(/bin/bash "${SCRIPT_PATH}" status --config "${fixture}/with-loader.json" --target bench --json)" || return 1
  assert_jq "${status_json}" '.overall_state == "PENDING"' 'mode-only file changes must be detected by itemized analysis' || return 1

  /bin/bash "${SCRIPT_PATH}" sync --config "${fixture}/with-loader.json" --target bench --json >/dev/null || return 1
  assert_equals "$(stat -f '%Lp' "${fixture}/target/wp-content/mu-plugins/loader.php")" "755" 'file component mode must be mirrored'
}

run_test 'warnings and not-empty diagnostics do not trigger sync loops' test_warnings_are_not_changes_or_repeat_sync_triggers
run_test 'rsync errors are explicit without full sync' test_rsync_errors_are_explicit_without_full_sync
run_test 'vanished files are retried without error or full sync' test_vanished_source_files_are_retried_without_error_or_full_sync
run_test 'file component rsync errors are captured explicitly' test_file_component_rsync_errors_are_captured
run_test 'only changed component is synchronized' test_only_changed_component_is_synchronized
run_test 'one component error does not block an independent selective sync' test_component_error_does_not_block_independent_sync
run_test 'sync removes all temporary analysis files' test_sync_cleans_temporary_analysis_files
run_test 'clean watch cycle scans each tree once' test_clean_watch_cycle_scans_each_tree_once
run_test 'analysis remains filesystem read-only' test_analysis_does_not_create_missing_component_directories
run_test 'lock prevents overlapping cycles' test_lock_prevents_overlapping_cycles
run_test 'abandoned lock is recovered' test_abandoned_lock_is_recovered
run_test 'missing target exits without restart loop' test_missing_target_exits_without_restart_loop
run_test 'idle backoff reduces scan frequency' test_idle_backoff_reduces_scan_frequency
run_test 'debounce groups rapid file changes' test_debounce_groups_rapid_file_changes
run_test 'logs rotate and remain concise' test_logs_rotate_and_remain_concise
run_test 'status aggregation covers CLEAN PENDING MISSING ERROR' test_status_aggregation_covers_all_states
run_test 'excludes match between analysis and sync' test_excludes_match_between_analysis_and_sync
run_test 'file components preserve archive metadata' test_file_component_preserves_archive_metadata

if [[ "${FAILURES}" -gt 0 ]]; then
  printf 'FAILED: %d wp-code-sync performance test(s)\n' "${FAILURES}" >&2
  exit 1
fi

printf 'PASS: wp-code-sync performance and reliability suite\n'

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/wp-code-sync-service.sh"
TEST_TEMP_DIR=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "expected output to contain: ${needle}"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" == *"${needle}"* ]]; then
    fail "expected output not to contain: ${needle}"
  fi
}

assert_jq_equals() {
  local json="$1"
  local query="$2"
  local expected="$3"
  local actual

  actual="$(printf '%s' "${json}" | jq -r "${query}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "expected jq ${query} to equal ${expected}, got ${actual}"
  fi
}

make_wp_tree() {
  local site_path="$1"

  mkdir -p \
    "${site_path}/wp-content/themes" \
    "${site_path}/wp-content/plugins"
}

create_config() {
  local config_path="$1"
  local target_site="$2"

  cat >"${config_path}" <<JSON
{
  "source_site": "${target_site}",
  "targets": [
    {
      "label": "test-site",
      "site_path": "${target_site}",
      "themes": ["anima"],
      "plugins": ["style-manager"]
    }
  ]
}
JSON
}

main() {
  TEST_TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TEST_TEMP_DIR}"' EXIT

  local target_site="${TEST_TEMP_DIR}/target"
  local config_path="${TEST_TEMP_DIR}/wp-code-mirror.config.json"
  local runtime_dir="${TEST_TEMP_DIR}/runtime"
  local status_json

  make_wp_tree "${target_site}"
  create_config "${config_path}" "${target_site}"

  status_json="$(env -i PATH='' /bin/bash "${SCRIPT_PATH}" status --config "${config_path}" --runtime-dir "${runtime_dir}" --target test-site --json)"

  assert_jq_equals "${status_json}" '.target_label' "test-site"
  assert_jq_equals "${status_json}" '.installed' "false"
  assert_jq_equals "${status_json}" '.running' "false"
  assert_contains "${status_json}" "\"sync_status\":null"

  local storage_runtime="${TEST_TEMP_DIR}/storage/tmp"
  local storage_status
  storage_status="$(env -i PATH='' /bin/bash "${SCRIPT_PATH}" status --config "${config_path}" \
    --runtime-dir "${storage_runtime}" --target test-site --json)"
  assert_jq_equals "${storage_status}" '.runner_path' "${TEST_TEMP_DIR}/storage/bin/wp-code-mirror-watch-test-site"

  local fake_home="${TEST_TEMP_DIR}/home"
  local fake_bin="${TEST_TEMP_DIR}/bin"
  local launchctl_log="${TEST_TEMP_DIR}/launchctl.log"
  local active_site="${TEST_TEMP_DIR}/active-site"
  local inactive_site="${TEST_TEMP_DIR}/inactive-site"
  local lifecycle_config="${TEST_TEMP_DIR}/lifecycle-config.json"
  mkdir -p "${fake_home}" "${fake_bin}"
  make_wp_tree "${active_site}"
  make_wp_tree "${inactive_site}"

  cat >"${fake_bin}/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${WPCM_TEST_LAUNCHCTL_LOG}"
if [[ "${1:-}" == "print" ]]; then
  if [[ "$*" == *"inactive-site"* || "$*" == *"missing-site"* \
    || ( "${WPCM_TEST_ACTIVE_LOADED:-0}" == "1" && "$*" == *"active-site"* ) ]]; then
    printf 'state = running\npid = 4242\n'
    exit 0
  fi
  if [[ "${WPCM_TEST_ACTIVE_LOADED:-0}" == "2" && "$*" == *"active-site"* ]]; then
    printf 'state = exited\nlast exit code = 78\n'
    exit 0
  fi
  exit 1
fi
exit 0
LAUNCHCTL
  chmod +x "${fake_bin}/launchctl"

  jq -n \
    --arg source "${active_site}" \
    --arg active "${active_site}" \
    --arg inactive "${inactive_site}" \
    '{
      source_site: $source,
      targets: [
        {label:"active-site",site_path:$active,active:true,themes:[],plugins:["style-manager"],mu_plugins:[]},
        {label:"inactive-site",site_path:$inactive,active:false,themes:[],plugins:["style-manager"],mu_plugins:[]},
        {label:"missing-site",site_path:"/definitely/missing",active:true,themes:[],plugins:["style-manager"],mu_plugins:[]}
      ]
    }' >"${lifecycle_config}"

  mkdir -p "${fake_home}/Library/LaunchAgents" "${runtime_dir}/bin"
  printf 'legacy keepalive plist\n' >"${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.inactive-site.plist"
  printf 'legacy keepalive plist\n' >"${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.missing-site.plist"
  printf '#!/bin/bash\n' >"${runtime_dir}/bin/wp-code-mirror-watch-inactive-site"
  printf '#!/bin/bash\n' >"${runtime_dir}/bin/wp-code-mirror-watch-missing-site"

  HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" \
    /bin/bash "${SCRIPT_PATH}" start-active --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" >/dev/null

  local active_plist="${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.active-site.plist"
  local active_runner="${runtime_dir}/bin/wp-code-mirror-watch-active-site"
  [[ -f "${active_plist}" ]] || fail "expected active target plist to be installed"
  [[ -x "${active_runner}" ]] || fail "expected a named active-target runner"
  [[ ! -f "${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.inactive-site.plist" ]] \
    || fail "inactive target must not be installed"
  [[ ! -f "${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.missing-site.plist" ]] \
    || fail "missing target must not be installed"

  local plist_contents runner_contents launchctl_calls
  plist_contents="$(<"${active_plist}")"
  runner_contents="$(<"${active_runner}")"
  launchctl_calls="$(<"${launchctl_log}")"
  assert_contains "${plist_contents}" "<key>KeepAlive</key>"
  assert_contains "${plist_contents}" "<false/>"
  assert_contains "${runner_contents}" "--interval \"15\""
  assert_contains "${runner_contents}" "--max-interval \"300\""
  assert_contains "${runner_contents}" "--debounce \"1\""
  assert_contains "${launchctl_calls}" "bootstrap"
  assert_contains "${launchctl_calls}" "active-site.plist"
  assert_contains "${launchctl_calls}" "bootout"
  assert_contains "${launchctl_calls}" "inactive-site"
  assert_contains "${launchctl_calls}" "missing-site"
  if printf '%s\n' "${launchctl_calls}" | grep 'bootstrap' | grep -Eq 'inactive-site|missing-site'; then
    fail "inactive or missing target must never be bootstrapped"
  fi

  : >"${launchctl_log}"
  HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" WPCM_TEST_ACTIVE_LOADED=1 \
    /bin/bash "${SCRIPT_PATH}" start-active --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" >/dev/null
  grep -E 'bootout .*/com\.wp-code-mirror\.sync\.active-site\.plist$' "${launchctl_log}" >/dev/null \
    || fail "start-active must unload a loaded legacy definition before rewriting it"

  : >"${launchctl_log}"
  HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" WPCM_TEST_ACTIVE_LOADED=1 \
    /bin/bash "${SCRIPT_PATH}" upgrade-active --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" >/dev/null
  if grep -Eq 'bootstrap|kickstart' "${launchctl_log}"; then
    fail "upgrade-active must rewrite safe definitions without starting watchers"
  fi
  grep -E 'bootout .*/com\.wp-code-mirror\.sync\.active-site\.plist$' "${launchctl_log}" >/dev/null \
    || fail "upgrade-active must unload an already-running active watcher before rewriting it"
  [[ -f "${active_plist}" ]] || fail "upgrade-active must preserve the active target definition"

  local exited_status
  exited_status="$(HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" WPCM_TEST_ACTIVE_LOADED=2 \
    /bin/bash "${SCRIPT_PATH}" status --runtime-dir "${runtime_dir}" --target active-site --json)"
  assert_jq_equals "${exited_status}" '.installed' "true"
  assert_jq_equals "${exited_status}" '.running' "false"
  assert_jq_equals "${exited_status}" '.state' "exited"

  printf 'legacy missing target plist\n' >"${fake_home}/Library/LaunchAgents/com.wp-code-mirror.sync.missing-site.plist"
  if HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" \
    /bin/bash "${SCRIPT_PATH}" start --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" \
      --target missing-site >/dev/null 2>&1; then
    fail "starting a missing target must fail even if a legacy plist exists"
  fi

  printf 'legacy keepalive plist\n' >"${active_plist}"
  : >"${launchctl_log}"
  HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" WPCM_TEST_ACTIVE_LOADED=1 \
    /bin/bash "${SCRIPT_PATH}" start --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" \
      --target active-site >/dev/null
  grep -F '<key>KeepAlive</key>' "${active_plist}" >/dev/null || fail "start must rewrite a legacy plist with safe lifecycle settings"
  grep -F '<false/>' "${active_plist}" >/dev/null || fail "start must disable KeepAlive in a legacy plist"
  grep -E 'bootout .*/com\.wp-code-mirror\.sync\.active-site\.plist$' "${launchctl_log}" >/dev/null \
    || fail "start must unload a loaded legacy definition before rewriting it"

  if HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" \
    /bin/bash "${SCRIPT_PATH}" install --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" \
      --target missing-site >/dev/null 2>&1; then
    fail "installing a missing target must fail in a controlled way"
  fi

  if HOME="${fake_home}" PATH="${fake_bin}:/usr/bin:/bin" WPCM_TEST_LAUNCHCTL_LOG="${launchctl_log}" \
    /bin/bash "${SCRIPT_PATH}" install --config "${lifecycle_config}" --runtime-dir "${runtime_dir}" \
      --target active-site --interval 0 >/dev/null 2>&1; then
    fail "invalid watcher intervals must fail before installing a crash-looping process"
  fi

  echo "PASS: wp-code-sync-service"
}

main "$@"

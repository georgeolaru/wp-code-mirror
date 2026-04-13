#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/wp-code-sync.sh"
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

assert_file_contains() {
  local path="$1"
  local needle="$2"

  [[ -f "${path}" ]] || fail "expected file to exist: ${path}"

  if ! grep -Fq "${needle}" "${path}"; then
    fail "expected ${path} to contain: ${needle}"
  fi
}

assert_missing() {
  local path="$1"

  if [[ -e "${path}" ]]; then
    fail "expected path to be absent: ${path}"
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
  local source_site="$2"
  local target_site="$3"

  cat >"${config_path}" <<JSON
{
  "source_site": "${source_site}",
  "targets": [
    {
      "label": "test-site",
      "site_path": "${target_site}",
      "themes": ["anima"],
      "plugins": ["pixelgrade-care", "nova-blocks", "style-manager"]
    }
  ],
  "rsync_excludes": [".DS_Store", ".git/"]
}
JSON
}

create_config_without_excludes() {
  local config_path="$1"
  local source_site="$2"
  local target_site="$3"

  cat >"${config_path}" <<JSON
{
  "source_site": "${source_site}",
  "targets": [
    {
      "label": "test-site",
      "site_path": "${target_site}",
      "themes": ["anima"],
      "plugins": ["pixelgrade-care", "nova-blocks", "style-manager"]
    }
  ]
}
JSON
}

main() {
  TEST_TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TEST_TEMP_DIR}"' EXIT

  local source_site="${TEST_TEMP_DIR}/source"
  local target_site="${TEST_TEMP_DIR}/target"
  local config_path="${TEST_TEMP_DIR}/wp-code-mirror.config.json"
  local config_without_excludes_path="${TEST_TEMP_DIR}/wp-code-mirror-no-excludes.config.json"
  local status_file="${TEST_TEMP_DIR}/status.json"

  make_wp_tree "${source_site}"
  make_wp_tree "${target_site}"

  mkdir -p \
    "${source_site}/wp-content/themes/anima/assets" \
    "${source_site}/wp-content/plugins/pixelgrade-care/includes" \
    "${source_site}/wp-content/plugins/nova-blocks/src" \
    "${source_site}/wp-content/plugins/style-manager/lib"

  printf 'source theme\n' >"${source_site}/wp-content/themes/anima/style.css"
  printf 'source asset\n' >"${source_site}/wp-content/themes/anima/assets/theme.txt"
  printf 'pixelgrade care\n' >"${source_site}/wp-content/plugins/pixelgrade-care/includes/bootstrap.php"
  printf 'nova blocks\n' >"${source_site}/wp-content/plugins/nova-blocks/src/index.js"
  printf 'style manager\n' >"${source_site}/wp-content/plugins/style-manager/lib/core.php"

  mkdir -p \
    "${target_site}/wp-content/themes/anima" \
    "${target_site}/wp-content/plugins/pixelgrade-care"
  printf 'stale theme\n' >"${target_site}/wp-content/themes/anima/stale.txt"
  printf 'stale plugin\n' >"${target_site}/wp-content/plugins/pixelgrade-care/old.php"

  create_config "${config_path}" "${source_site}" "${target_site}"
  create_config_without_excludes "${config_without_excludes_path}" "${source_site}" "${target_site}"

  local status_before
  status_before="$(bash "${SCRIPT_PATH}" status --config "${config_path}" --target test-site)"
  assert_contains "${status_before}" "PENDING"
  assert_contains "${status_before}" "themes/anima"
  assert_contains "${status_before}" "plugins/pixelgrade-care"

  local status_with_empty_path
  status_with_empty_path="$(env -i PATH='' /bin/bash "${SCRIPT_PATH}" status --config "${config_path}" --target test-site)"
  assert_contains "${status_with_empty_path}" "PENDING"
  assert_contains "${status_with_empty_path}" "themes/anima"
  assert_contains "${status_with_empty_path}" "plugins/pixelgrade-care"

  local status_without_excludes
  status_without_excludes="$(env -i PATH='' /bin/bash "${SCRIPT_PATH}" status --config "${config_without_excludes_path}" --target test-site)"
  assert_contains "${status_without_excludes}" "PENDING"
  assert_contains "${status_without_excludes}" "themes/anima"
  assert_contains "${status_without_excludes}" "plugins/pixelgrade-care"

  bash "${SCRIPT_PATH}" sync --config "${config_path}" --target test-site >/dev/null

  assert_file_contains "${target_site}/wp-content/themes/anima/style.css" "source theme"
  assert_file_contains "${target_site}/wp-content/themes/anima/assets/theme.txt" "source asset"
  assert_missing "${target_site}/wp-content/themes/anima/stale.txt"
  assert_file_contains "${target_site}/wp-content/plugins/pixelgrade-care/includes/bootstrap.php" "pixelgrade care"
  assert_missing "${target_site}/wp-content/plugins/pixelgrade-care/old.php"
  assert_file_contains "${target_site}/wp-content/plugins/nova-blocks/src/index.js" "nova blocks"
  assert_file_contains "${target_site}/wp-content/plugins/style-manager/lib/core.php" "style manager"

  local status_json
  status_json="$(bash "${SCRIPT_PATH}" status --config "${config_path}" --target test-site --json)"
  assert_jq_equals "${status_json}" '.source_site' "${source_site}"
  assert_jq_equals "${status_json}" '.targets[0].label' "test-site"
  assert_jq_equals "${status_json}" '.targets[0].state' "CLEAN"

  bash "${SCRIPT_PATH}" sync --config "${config_path}" --target test-site --status-file "${status_file}" >/dev/null
  [[ -f "${status_file}" ]] || fail "expected status file to exist"
  assert_file_contains "${status_file}" "\"last_sync_at\""
  assert_file_contains "${status_file}" "\"state\": \"CLEAN\""

  local status_after
  status_after="$(bash "${SCRIPT_PATH}" status --config "${config_path}" --target test-site)"
  assert_contains "${status_after}" "CLEAN"

  echo "PASS: wp-code-sync"
}

main "$@"

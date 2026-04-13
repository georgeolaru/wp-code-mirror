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

  echo "PASS: wp-code-sync-service"
}

main "$@"

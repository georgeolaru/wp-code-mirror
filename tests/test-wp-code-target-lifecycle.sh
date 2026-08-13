#!/usr/bin/env bash

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wp-code-target-lifecycle.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/config" "${TEST_ROOT}/source/wp-content/themes" \
  "${TEST_ROOT}/source/wp-content/plugins/alpha" "${TEST_ROOT}/target/wp-content/themes" \
  "${TEST_ROOT}/target/wp-content/plugins" "${TEST_ROOT}/home/Library/LaunchAgents"
cp "${PLUGIN_ROOT}/scripts/wp-code-target.sh" "${TEST_ROOT}/scripts/wp-code-target.sh"

cat >"${TEST_ROOT}/scripts/wp-code-sync.sh" <<'SYNC'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >>"${WPCM_TARGET_TEST_LOG}"
SYNC

cat >"${TEST_ROOT}/scripts/wp-code-sync-service.sh" <<'SERVICE'
#!/usr/bin/env bash
printf 'service %s\n' "$*" >>"${WPCM_TARGET_TEST_LOG}"
SERVICE

cat >"${TEST_ROOT}/config/wp-code-mirror.config.json" <<JSON
{
  "source_site": "${TEST_ROOT}/source",
  "targets": [],
  "rsync_excludes": []
}
JSON

chmod +x "${TEST_ROOT}/scripts/"*.sh
export WPCM_TARGET_TEST_LOG="${TEST_ROOT}/commands.log"

HOME="${TEST_ROOT}/home" /bin/bash "${TEST_ROOT}/scripts/wp-code-target.sh" add lifecycle-test \
  --site-path "${TEST_ROOT}/target" --plugins alpha \
  --config "${TEST_ROOT}/config/wp-code-mirror.config.json" >/dev/null

grep -F 'service install' "${WPCM_TARGET_TEST_LOG}" >/dev/null \
  || fail 'target add must delegate LaunchAgent lifecycle to wp-code-sync-service.sh'
grep -F -- '--interval 15' "${WPCM_TARGET_TEST_LOG}" >/dev/null \
  || fail 'target add must use the safe 15-second default interval'
jq -e '.targets[0].active == true' "${TEST_ROOT}/config/wp-code-mirror.config.json" >/dev/null \
  || fail 'new target must be explicitly active'

printf 'PASS: target lifecycle delegates to the safe service implementation\n'

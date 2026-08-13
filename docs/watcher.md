# Watcher Performance and Lifecycle

WP Code Mirror uses one lightweight watcher process per explicitly active
target. Separate processes keep failures isolated, while the polling policy
prevents dozens of inactive targets from continuously walking the filesystem.
No new host dependency is required beyond Bash, `jq`, `rsync`, and `launchd`.

## One Analysis Per Cycle

A cycle performs one dry-run analysis for every configured component in its
target. Directory analysis uses `rsync --itemize-changes` with a private output
prefix. Only prefixed itemized lines are real differences; unprefixed output is
a diagnostic.

The same analysis object drives all three outcomes:

1. whether synchronization is needed;
2. exactly which components are synchronized;
3. the status JSON written for wp-admin.

After synchronization, WP Code Mirror updates the analyzed component from the
sync result. It does not immediately rescan the same trees. A later cycle will
detect a file that changed during synchronization.

Warnings such as `not empty, cannot delete` are recorded separately and do not
trigger a sync. A real non-zero `rsync` failure produces `ERROR` and never
falls back to syncing every component. Exit code 24 (a source file vanished
during the scan) is transient: the item remains `PENDING` for another analysis,
but is not treated as a hard error or an itemized difference.

## Polling, Debounce, and Backoff

Defaults for an installed watcher are:

- base interval: 15 seconds;
- debounce: 1 second before analysis;
- maximum idle interval: 300 seconds;
- idle sequence: 15-second base, then 30, 60, 120, 240, and 300 seconds;
- any detected change, retry, or error resets the next interval to 15 seconds.

The debounce groups a rapid sequence of writes before the one recursive
analysis begins. Backoff means a stable target settles at one cycle every five
minutes rather than one cycle every two seconds.

For an explicitly supervised test, `watch` also accepts `--max-cycles`. This is
useful for fixtures and benchmarks; installed services remain continuous until
stopped.

## Per-Target Locking

Every status, sync, or watch cycle acquires an atomic directory lock under:

```text
wp-content/uploads/wp-code-mirror/tmp/locks/<target>.lock
```

The lock stores its owner PID. A live owner causes a second command to exit
with temporary-failure code 75 before it scans. A dead owner is recovered, and
normal exits and signals release the current lock. This prevents a manual sync,
an admin status request, and a watcher cycle from traversing the same target at
the same time.

## Logs and Status

Watchers write their own concise logs rather than sending normal output to
launchd. The default maximum is 1 MiB per active log. When the limit is reached,
the current file becomes `.1` and a new file starts. One rotated generation is
kept. Existing historical logs are not deleted by upgrades or target removal.

Normal logs contain only lifecycle and useful events:

- watcher start and stop;
- stale-lock recovery;
- changed components detected;
- components synchronized;
- compact warning counts.

Hard errors go to the target error log. Clean cycles do not emit a `SYNCED`
line for every component. The wp-admin bridge reads files backwards in chunks,
so displaying the final lines does not load a large historical log into PHP
memory.

Status JSON caps samples at 100 itemized changes and 10 unique warnings/errors
per component while retaining total counts. Diagnostics and changes are never
mixed. Aggregate state precedence is:

1. `ERROR` — at least one component or target has a hard failure;
2. `MISSING` — no hard failure, but a target is missing or inactive;
3. `PENDING` — at least one real difference or transient retry remains;
4. `CLEAN` — all analyzed components match.

## Active and Inactive Targets

Targets accept an `active` boolean. Older configs that omit it default to
`true`. wp-admin exposes the same setting.

Rewrite all eligible watcher definitions without starting them with:

```bash
bash scripts/wp-code-sync-service.sh upgrade-active \
  --config /absolute/path/to/wp-code-mirror.config.json
```

`start-active` installs and starts active targets whose WordPress directories
exist. It unloads and removes legacy persistent definitions for inactive or
missing targets, while leaving their logs intact. A watcher that encounters a
target disappearing at runtime writes `MISSING` once and exits successfully.
LaunchAgents use `KeepAlive=false`, so neither this exit nor an invalid process
can become a crash/restart loop.

Saving the wp-admin configuration compares the old and new effective service
config. It restarts only installed targets whose source, exclusions, path, or
component lists changed. Newly inactive, removed, or missing targets are
uninstalled; unaffected installed services are untouched.

## Large Directories and Exclusions

The exact same exclusion arguments are used for analysis and real sync.
Excluded files are not copied and remain protected from `--delete`; WP Code
Mirror intentionally does not use `--delete-excluded`. On older `rsync`, a
protected file inside an otherwise stale directory may produce `not empty,
cannot delete`. That warning is visible but does not make the component
`PENDING`.

Reasonable development-only defaults include:

- `.git/`, `.github/`, `.idea/`, `.vscode/`, `.worktrees/`;
- `node_modules/`, `tmp/`, `.phpunit.cache/`, `coverage/`;
- source maps (`*.map`) and common editor metadata.

Do not exclude `vendor/` globally. Many WordPress plugins load Composer
packages at runtime. For a large plugin such as Style Manager, classify its
directories before adding project-specific exclusions:

- keep runtime code such as `src/`, built assets, `vendor_prefixed/`, and any
  Composer packages loaded by the plugin;
- exclude reproducible development dependencies only when the target does not
  execute them (for example a project-specific test tool subtree);
- exclude caches, temporary builds, coverage, worktrees, and volatile output;
- keep the same pattern in the shared config so analysis and sync agree.

## Upgrading Existing LaunchAgents

Previously installed per-target plists may contain `KeepAlive=true` and a
2-second interval. Keep every watcher stopped while upgrading, then regenerate
only active/present targets:

```bash
uid="$(id -u)"
for plist in "$HOME"/Library/LaunchAgents/com.wp-code-mirror.sync.*.plist; do
  [ -e "$plist" ] || continue
  label="$(basename "$plist" .plist)"
  launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
done

bash scripts/wp-code-sync-service.sh upgrade-active \
  --config /absolute/path/to/wp-code-mirror.config.json
```

The first loop unloads legacy jobs without deleting logs. `upgrade-active`
rewrites eligible definitions with safe defaults and retires definitions for
configured inactive or missing targets, but starts nothing. Use per-target
`start`, or `start-active`, only after you intentionally decide which active
watchers should run. Use `stop` or `uninstall` when no persistent watcher should
remain loaded.

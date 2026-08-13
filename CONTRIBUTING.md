# Contributing

WP Code Mirror is still an early prototype, so the most useful contributions
are focused, practical, and easy to verify.

## Before You Start

Please keep the current product scope in mind:

- local development workflow only
- code mirroring only
- no content sync
- no database sync
- no deployment scope

## Good Contributions

- bug fixes in the admin plugin
- setup and install documentation improvements
- watcher reliability improvements
- clearer error messages
- tests for config, path, and sync behavior

## Development Notes

The repository currently contains:

- the WordPress admin plugin
- the sync script
- the service/watcher script
- lightweight tests for config, paths, and sync behavior

The current watcher/service flow is macOS-first because it uses `launchd`.

## Running The Existing Checks

PHP checks:

```bash
php -l wp-code-mirror.php
php tests/test-config-repository.php
php tests/test-paths.php
php tests/test-host-bridge-tail.php
php tests/test-host-bridge-status-cache.php
php tests/test-host-bridge-service-fallback.php
php tests/test-admin-service-reconciliation.php
```

Sync script test:

```bash
bash tests/test-wp-code-sync.sh
bash tests/test-wp-code-sync-performance.sh
bash tests/test-wp-code-sync-service.sh
bash tests/test-wp-code-target-lifecycle.sh
```

## Pull Requests

When opening a PR, keep it narrow:

- explain the problem
- explain the behavior change
- mention how you tested it
- call out any platform assumptions or limitations

Documentation fixes and setup improvements are welcome, especially when they
make the current prototype easier to understand or test.

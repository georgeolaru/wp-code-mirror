# WP Code Mirror Installation

## Scope

WP Code Mirror currently targets local development workflows where:

- one WordPress install acts as the source of truth
- one or more WordPress installs act as test targets
- only selected theme and plugin code is mirrored

This is not a deployment flow and it does not sync content or databases.

## Current Platform Assumptions

The current watcher/service flow is macOS-first.

The WordPress admin plugin itself is normal PHP, but the host-side service
currently depends on:

- `bash`
- `rsync`
- `jq`
- `launchctl` / `launchd`

## Prerequisites

Before using the watcher flow, make sure all of these are true:

1. You have at least two local WordPress installs.
2. Each site has a real `wp-content/themes` and `wp-content/plugins` directory.
3. The source site contains the theme/plugin code you actively develop.
4. The target sites already exist as valid WordPress installs.
5. `rsync` and `jq` are available in your shell.

You can verify the required tools with:

```bash
command -v bash
command -v rsync
command -v jq
command -v launchctl
```

## Plugin Install

Clone the plugin into the source site's plugins directory:

```bash
git clone git@github.com:georgeolaru/wp-code-mirror.git wp-code-mirror
```

Then:

1. Activate `WP Code Mirror` in wp-admin.
2. Open `Tools -> WP Code Mirror`.
3. Set the source site path.
4. Add one or more target sites.
5. List the theme/plugin slugs you want mirrored.
6. Save the config.

When saved from wp-admin, the active config is written to:

```text
wp-content/uploads/wp-code-mirror/config/wp-code-mirror.config.json
```

## Example Config

Start from:

```text
config/wp-code-mirror.config.example.json
```

The sample uses realistic local-site paths and two targets:

- `smoke-site`
- `qa-site`

Adjust:

- `source_site`
- each target `site_path`
- the theme slugs
- the plugin slugs

The slugs must match actual directories inside `wp-content/themes` and
`wp-content/plugins`.

### Mu-Plugins

Each target also accepts an optional `mu_plugins` array. Entries map to
`wp-content/mu-plugins/<slug>` on both source and target. Mu-plugins are
commonly split into a loader file plus a companion directory — list them
as two separate entries:

```json
"mu_plugins": [
  "type-system-transfusion.php",
  "type-system-transfusion"
]
```

File entries sync a single `.php` file. Directory entries sync recursively
with `--delete`, matching the existing theme/plugin behavior. The target's
`wp-content/mu-plugins/` directory is created on demand.

## What The Paths Should Look Like

Example source site:

```text
/Users/you/Local Sites/theme-lab/app/public
```

Expected source directories:

```text
/Users/you/Local Sites/theme-lab/app/public/wp-content/themes
/Users/you/Local Sites/theme-lab/app/public/wp-content/plugins
```

Example target site:

```text
/Users/you/Local Sites/theme-smoke/app/public
```

Expected target directories:

```text
/Users/you/Local Sites/theme-smoke/app/public/wp-content/themes
/Users/you/Local Sites/theme-smoke/app/public/wp-content/plugins
```

## Watcher And Service Flow

The plugin uses two host-side scripts:

- `scripts/wp-code-sync.sh`
- `scripts/wp-code-sync-service.sh`

The service script installs a per-target LaunchAgent and writes status/log files
under:

```text
wp-content/uploads/wp-code-mirror/tmp
```

Each target gets:

- a status JSON file
- a stdout log
- a stderr log

## Manual Sanity Check

After saving the config, you can verify sync status manually:

```bash
bash scripts/wp-code-sync.sh status --config /absolute/path/to/wp-code-mirror.config.json --target smoke-site
```

Run a one-off sync manually:

```bash
bash scripts/wp-code-sync.sh sync --config /absolute/path/to/wp-code-mirror.config.json --target smoke-site
```

Install and start the watcher service manually:

```bash
bash scripts/wp-code-sync-service.sh install --config /absolute/path/to/wp-code-mirror.config.json --target smoke-site
```

Check service status:

```bash
bash scripts/wp-code-sync-service.sh status --config /absolute/path/to/wp-code-mirror.config.json --target smoke-site --json
```

## Troubleshooting

If setup does not work, check these first:

- the source site path is the WordPress root, not just `wp-content`
- each target site path is also a WordPress root
- the listed theme/plugin slugs exist in the source site
- `jq` and `rsync` are available to the shell running the scripts
- the target label you run from the terminal matches the config exactly

If the service appears installed but not running, inspect:

- the LaunchAgent plist in `~/Library/LaunchAgents`
- the stdout log in `wp-content/uploads/wp-code-mirror/tmp`
- the stderr log in `wp-content/uploads/wp-code-mirror/tmp`

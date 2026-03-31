# WP Code Mirror

> Test across many WordPress sites from one working codebase.

WP Code Mirror helps WordPress developers keep one in-development theme or
plugin aligned across many local WordPress sites. Instead of reinstalling ZIPs,
copying folders manually, or maintaining duplicate code trees, you work from a
single source of truth and mirror that code into your target sites.

## Quick Start

Clone the repository directly into your WordPress plugins directory:

```bash
git clone <repo-url> wp-content/plugins/wp-code-mirror
```

Then:

1. activate the `WP Code Mirror` plugin in wp-admin
2. copy `config/wp-code-mirror.config.example.json` to `config/wp-code-mirror.config.json`
3. update the source and target site paths
4. open `Tools -> WP Code Mirror`
5. install and start the watcher for your target site

## What It Does

- keeps one local theme or plugin codebase as the source of truth
- mirrors that code into one or more WordPress test sites
- surfaces sync and watcher status inside wp-admin
- reduces duplicate-copy maintenance in local development workflows

## Why This Exists

If you develop WordPress code locally, you usually do not stop at one site.

You build in one working install, then verify the same code in:

- smoke sites
- client-like setups
- sites with different plugin stacks
- sites with different content and design contexts

That is where local development starts to break down. The source site has the
latest code, the test sites drift out of date, and maintaining those copies
becomes work on its own.

WP Code Mirror is built to remove that friction.

## How It Works

WP Code Mirror uses two parts:

1. A WordPress admin plugin
   - manages mirror config
   - shows watcher status
   - exposes sync and service controls

2. A host-side watcher/service layer
   - mirrors selected theme and plugin directories
   - keeps target sites aligned automatically
   - writes status snapshots and logs that wp-admin can display

The working model is simple:

- choose one local WordPress install as the source of truth
- select the theme/plugin code you are actively developing
- configure one or more target WordPress sites
- let the watcher keep those targets in sync

## Prototype Setup

This repository currently represents a productized prototype, not a polished
distribution package.

Today the project contains:

- a WordPress plugin at the repository root
- host-side sync scripts in [`scripts/`](scripts)
- an example config in [`config/`](config)
- positioning and launch documents in [`docs/`](docs)

The current host-side workflow is macOS-first and relies on `rsync`, `jq`, and
`launchd`.

## Current Prototype Scope

The current prototype supports:

- one source install
- multiple local target sites
- selected themes and plugins
- config editing from wp-admin
- per-target watcher status in wp-admin
- host-side sync via `rsync`
- automatic watcher startup on macOS with `launchd`

## Current Limitations

This is still an early open-source prototype.

- The current watcher service is macOS-first.
- The existing codebase grew out of a real internal workflow and still needs
  some packaging cleanup.
- It is focused on local development, not deployment.
- It syncs code only, not content or databases.

## Repository Layout

```text
assets/
config/
  wp-code-mirror.config.example.json
docs/
  positioning.md
  launch-plan.md
includes/
tests/
scripts/
  wp-code-sync.sh
  wp-code-sync-service.sh
wp-code-mirror.php
README.md
```

## Who It Is For

WP Code Mirror is for WordPress developers who:

- build themes or plugins locally
- test across multiple local sites
- want one working codebase instead of many stale copies
- are tired of ZIP reinstall loops and manual sync work

## Roadmap

Short term:

- clean public packaging and naming
- improve installation flow
- add screenshots and a short demo
- document real setup steps end to end

Next:

- improve admin UX
- expand beyond macOS-specific service management
- harden sync controls and logs
- make multi-site workflows easier to configure

## Status

WP Code Mirror is in active prototype stage.

The concept is real, the workflow is useful, and the current repo is being
shaped into a standalone open-source developer tool.

## Planned GitHub Presentation Improvements

- add screenshots from the wp-admin interface
- add a short demo GIF
- document installation for a clean local environment
- prepare a publishable plugin package

## Contributing

Contributions, workflow feedback, and naming/packaging suggestions are welcome.

The most useful feedback right now is:

- how you currently test one codebase across many WordPress sites
- where local WordPress workflows become repetitive
- what would make a tool like this easier to trust

## License

MIT. See [`LICENSE`](LICENSE).

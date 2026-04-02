=== WP Code Mirror ===
Contributors: georgeolaru
Tags: wordpress, wordpress-plugin, plugin-development, theme-development, local-development, developer-tools
Requires at least: 6.0
Tested up to: 7.0
Requires PHP: 7.4
Stable tag: 0.1.0
License: MIT
License URI: https://opensource.org/licenses/MIT

One theme or plugin codebase. Many WordPress test sites.

== Description ==

WP Code Mirror is a local-first workflow tool for WordPress developers who need
to test the same in-development theme or plugin across multiple local
WordPress sites.

Instead of reinstalling ZIPs, copying folders manually, or maintaining
duplicate code trees, you keep one source of truth and mirror selected theme
and plugin code into your target sites.

WP Code Mirror currently includes:

* a WordPress admin plugin for mirror configuration and status
* a host-side watcher/service layer that syncs selected theme and plugin code
* a local development workflow for testing the same code across multiple sites

This plugin is for:

* theme and plugin developers working locally
* multi-site local testing workflows
* smoke, demo, and QA-style WordPress test sites

This plugin is not for:

* deployment
* content sync
* database migration
* full-site cloning

Current status: early macOS-first prototype. The current watcher/service flow
depends on `rsync`, `jq`, and `launchd`.

== Installation ==

1. Clone or copy `wp-code-mirror` into your site's `wp-content/plugins` directory.
2. Activate `WP Code Mirror` in wp-admin.
3. Open `Tools -> WP Code Mirror`.
4. Set the source site path and one or more target site paths.
5. Save the config.
6. Install and start the watcher for each target site you want to keep in sync.

You can optionally pre-seed the configuration from
`config/wp-code-mirror.config.example.json`. If you configure the plugin from
wp-admin, it writes the site-local config to
`wp-content/uploads/wp-code-mirror/config/wp-code-mirror.config.json`.

== Frequently Asked Questions ==

= What does WP Code Mirror actually sync? =

Only selected theme and plugin code. It does not sync content, media, users,
settings, or databases.

= Is this a deployment tool? =

No. WP Code Mirror is for local development workflows.

= Why use this instead of manual copying or ZIP reinstalls? =

Manual copy and reinstall workflows create drift over time. WP Code Mirror
keeps one active source of truth and mirrors that selected code into one or
more target sites for testing.

= Why not just use symlinks? =

Symlinks can be a valid local workflow, but they are not always the right fit
for every WordPress setup, target site, or plugin stack. WP Code Mirror keeps
the workflow explicit and per-target.

= Does it work outside macOS? =

The admin plugin is portable PHP, but the current watcher/service flow is
macOS-first because it relies on `launchd`.

== Changelog ==

= 0.1.0 =

* Initial public prototype of the WordPress admin plugin and host watcher workflow.

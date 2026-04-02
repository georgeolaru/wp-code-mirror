# WP Code Mirror Positioning

## Name

WP Code Mirror

## Tagline

One theme or plugin codebase. Many WordPress test sites.

## Product Summary

WP Code Mirror is a local-first workflow tool for WordPress theme and plugin
development. It helps developers keep one in-development source of code aligned
across multiple local WordPress sites, so they can verify more use cases
without reinstalling ZIPs, copying folders manually, or maintaining duplicate
plugin and theme copies.

## Core Problem

WordPress developers rarely work with just one local site.

They build a theme or plugin in one working install, then need to test it
across other sites with different content, settings, plugin stacks, or visual
contexts. That usually creates code drift:

- one site has the latest source
- other sites have stale copies
- smoke sites stop reflecting reality
- developers spend time maintaining test setups instead of testing behavior

WP Code Mirror solves that by keeping a single active codebase as the source of
truth while mirroring it into one or more target WordPress sites.

## Audience

Primary audience:

- WordPress developers working locally across multiple sites

Secondary audience:

- plugin and theme authors
- agency teams maintaining smoke sites
- product teams validating changes in multiple local contexts

## What It Is

- a WordPress admin plugin for config and status
- a host-side watcher and service layer for automatic sync
- a local development workflow tool

## What It Is Not

- not a deployment platform
- not a content sync tool
- not a database migration tool
- not a cloud SaaS product in phase one

## Messaging Pillars

### 1. One working codebase

Develop in one place. Keep that codebase as the source of truth.

### 2. Many WordPress test sites

Validate the same in-development theme or plugin in multiple local
environments.

### 3. Less maintenance overhead

Avoid ZIP reinstalls, duplicate copies, and manual folder syncing.

### 4. Local-first and transparent

The tool uses normal files, normal scripts, and a visible watcher status inside
wp-admin.

## Short Product Pitch

WP Code Mirror helps WordPress developers test one in-development theme or
plugin across many local sites while keeping a single working codebase as the
source of truth.

## Longer Product Pitch

When you develop WordPress plugins or themes, the real problem is not writing
code in one local site. The real problem starts when you need to test that same
in-development code across many other local sites. The usual fallback is manual
copying, ZIP reinstall workflows, or stale duplicate code trees. WP Code Mirror
removes that friction by mirroring selected theme and plugin directories from
one working source into multiple target WordPress sites and showing watcher
status directly inside wp-admin.

## Naming Rationale

The name keeps the category obvious:

- `WP` signals the target ecosystem immediately
- `Code` emphasizes the source-of-truth development workflow
- `Mirror` describes the main mechanism without implying deployment or content
  cloning

## Release Positioning

Phase one should be positioned as:

- open source
- developer-first
- local-only
- practical and transparent

The launch should avoid framing it as a hosted platform or as a general
WordPress migration product.

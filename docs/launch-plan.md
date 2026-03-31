# WP Code Mirror Launch Plan

## Goal

Prepare WP Code Mirror as a clean, presentable GitHub project with clear
positioning, a strong README, and a repo structure that can grow into a real
open-source product.

## Phase 1 Outcome

Ship a public-facing repository that communicates:

- what problem WP Code Mirror solves
- who it is for
- how it works
- what the current prototype already does
- what the roadmap looks like

## Deliverables

### 1. Repository

- repo name: `wp-code-mirror`
- local git initialization
- clean top-level structure

### 2. Presentable README

The README should include:

- name and tagline
- problem statement
- how it works
- current feature set
- current limitations
- installation overview
- roadmap
- contribution invitation

### 3. Positioning Documents

- `docs/positioning.md`
- `docs/launch-plan.md`

### 4. Prototype Source Inclusion

Include the current prototype source as reference material:

- WordPress admin plugin
- host sync script
- host service script

## Repository Narrative

The repo should tell a coherent story:

1. WordPress developers need to test one codebase across many sites.
2. Local environments create stale copies and maintenance friction.
3. WP Code Mirror keeps one source of truth aligned across target sites.
4. The first release is local-first and open source.

## README Priorities

The README should optimize for:

- fast understanding in under 30 seconds
- immediate relevance for WordPress developers
- believable scope
- clean, non-hyped language

## Near-Term Roadmap

- improve plugin naming and packaging consistency
- separate product repo structure from the original prototype workspace
- add screenshots and a short demo GIF
- refine cross-platform service support beyond macOS LaunchAgents
- harden admin actions and installation flow
- add a proper install guide for real-world usage

## Launch Risks

1. The current prototype still reflects a project-specific origin.
2. The service layer is macOS-specific in the current version.
3. Public launch quality will depend heavily on README clarity because the
   concept is new to most WordPress developers.

## Recommendation

Launch the repo as an honest, useful prototype:

- emphasize the workflow problem clearly
- describe current platform limits explicitly
- invite feedback from developers who test plugins/themes across multiple local
  sites

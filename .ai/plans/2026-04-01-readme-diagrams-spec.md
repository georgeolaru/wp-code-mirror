# README Diagram Spec

Date: 2026-04-01
Status: Approved for implementation

## Goal

Replace the current README `before / after` diagrams with denser visuals that
communicate the WP Code Mirror workflow more clearly on GitHub.

## Audience

- WordPress developers testing one in-development theme or plugin across
  multiple local sites
- Readers scanning the README quickly and deciding whether the plugin solves
  their workflow problem

## Constraints

- Keep the `before / after` structure
- Use a semi-technical level of detail
- Final format should be GitHub-visible `SVG`
- Keep the composition inspired by the provided reference image
- Adapt the palette to a newer WordPress-like style rather than using the
  reference's monochrome outline treatment

## Messaging

### Before

- A single source codebase exists on the left
- Distribution is fragmented in the middle
- Three target site cards on the right show inconsistent code states
- Problem cues include `manual copy`, `zip reinstall`, and `missed update`

### After

- The same source codebase exists on the left
- A single `watcher sync` mechanism sits in the middle
- The same three target site cards on the right show aligned, synced code
- The diagram must make the system feel simpler and more reliable than the
  `before` version

## Visual Language

- Horizontal composition with three columns: source, mechanism, targets
- Compact cards instead of broad sparse boxes
- Repeated module blocks for `theme`, `plugin-a`, and `plugin-b`
- Rounded corners, clean strokes, soft fills
- Blue/slate as primary structure colors
- Restrained amber accents for drift/problem states in `before`
- Restrained green accents for healthy sync states in `after`

## Explicit Exclusions

- Do not imply full-site cloning
- Do not imply content or database sync
- Do not show `wp-admin` as a visible mechanism in the `after` diagram
- Do not use ASCII as the final output

## Integration

- Store diagram assets under `docs/assets/`
- Replace the existing Mermaid blocks in `README.md`
- Keep surrounding product messaging largely unchanged

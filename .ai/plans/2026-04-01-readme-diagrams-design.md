# README Diagram Design

Date: 2026-04-01
Status: In progress

## Goal

Replace the current `before / after` README diagrams with a denser visual system
that explains WP Code Mirror more clearly and feels more intentional.

## Approved Decisions

- Keep the `before / after` structure.
- Increase visual density and clarity compared to the current Mermaid diagrams.
- Use a semi-technical level of detail.
- Export diagrams as `SVG` for GitHub README usage.
- Use the reference image mainly for composition, not for exact styling.
- Adapt the palette to a newer WordPress visual style instead of keeping the
  reference's monochrome treatment.

## Diagram Direction

Recommended direction: `Narrative cards`

- `Before`: source codebase on the left, fragmented distribution path in the
  middle, target site cards on the right with mixed states like `stale`,
  `manual copy`, `zip reinstall`, and `missed update`.
- `After`: same source codebase on the left, a single `watcher sync` mechanism
  in the middle, and the same target site cards on the right with aligned,
  synced code states.

## Composition Notes

- Keep a clean horizontal flow inspired by the reference image.
- Use compact blocks instead of wide, sparse layouts.
- Repeat a small icon and card language consistently across both diagrams.
- Keep green limited to healthy synced states.
- Use blue/slate as the primary structural palette.
- Use restrained amber accents for drift/problem states in `before`.

## Explicit Exclusions

- Do not imply full-site cloning, content sync, or database sync.
- Do not include `wp-admin` as a visible mechanism in the `after` diagram.
- Do not use ASCII as the final delivery format.

# README Diagrams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the README Mermaid diagrams with two GitHub-friendly SVG diagrams that explain WP Code Mirror more clearly.

**Architecture:** Add two standalone SVG assets under `docs/assets/` and swap the README diagram embeds to image references. The diagrams share one visual language so the reader can compare `before` and `after` instantly.

**Tech Stack:** Markdown, SVG

---

### Task 1: Finalize the written design record

**Files:**
- Create: `.ai/plans/2026-04-01-readme-diagrams-spec.md`
- Create: `.ai/plans/2026-04-01-readme-diagrams-implementation-plan.md`

- [x] **Step 1: Write the approved spec**
- [x] **Step 2: Write the implementation plan**

### Task 2: Create the `before` SVG

**Files:**
- Create: `docs/assets/wp-code-mirror-before.svg`

- [ ] **Step 1: Draw the source card with `theme`, `plugin-a`, and `plugin-b` modules**
- [ ] **Step 2: Add fragmented distribution lines and problem labels**
- [ ] **Step 3: Add three target cards with mixed `synced` and `stale` states**
- [ ] **Step 4: Review the SVG text for GitHub readability**

### Task 3: Create the `after` SVG

**Files:**
- Create: `docs/assets/wp-code-mirror-after.svg`

- [ ] **Step 1: Reuse the same source and target card language**
- [ ] **Step 2: Add the central `watcher sync` card**
- [ ] **Step 3: Normalize all target states to `synced` with subtle success accents**
- [ ] **Step 4: Review the SVG text for GitHub readability**

### Task 4: Update README integration

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace both Mermaid blocks with SVG image references**
- [ ] **Step 2: Preserve existing section structure and explanatory copy**
- [ ] **Step 3: Verify the README still reads cleanly without Mermaid**

### Task 5: Final review

**Files:**
- Review: `README.md`
- Review: `docs/assets/wp-code-mirror-before.svg`
- Review: `docs/assets/wp-code-mirror-after.svg`

- [ ] **Step 1: Check file paths and alt text**
- [ ] **Step 2: Re-read the diagrams for messaging accuracy**
- [ ] **Step 3: Confirm the visuals do not imply content or database sync**

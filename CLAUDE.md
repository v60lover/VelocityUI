# VelocityUI — Claude Code Instructions

## Project Overview

VelocityUI is a Swift 6 package library for high-performance scrolling feeds and grids with videos, GIFs, and images on iOS. CALayer-backed render engine with Swift Concurrency-native architecture. See `velocityui-prompt.md` for full architecture spec.

---

## Core Rules

### Never Commit
**NEVER create git commits.** Do not run `git commit`, `git push`, or any destructive git operation. Only read git state (`git status`, `git diff`, `git log`). All committing is done manually by the user.

### Swift File Headers
Swift files must have **only the filename** as the header comment — no license, no author, no copyright, no date:

```swift
// FileName.swift
```

Nothing else. No `//  Created by`, no `//  Copyright`, no license block.

---

## Skills — Always Check Before Acting

This project uses **Superpowers** (skill-first workflow). Before responding to any request — even clarifying questions — check if a skill applies and invoke it first.

### Installed Skills

| Skill | When to Use |
|---|---|
| `using-superpowers` | Loaded at session start — establishes skill-first discipline |
| `beads-workflow` | Converting plans/specs into beads (tasks with dependencies) for agent execution |
| `ralph-tui-create-beads` | Converting PRDs into beads for ralph-tui autonomous execution |
| `gitnexus-exploring` | Understanding architecture, tracing execution flows, exploring unfamiliar code |
| `gitnexus-debugging` | Tracing bugs, understanding why something fails |
| `gitnexus-refactoring` | Renaming, extracting, splitting, moving code safely |
| `gitnexus-impact-analysis` | Safety analysis before editing — what will break? |
| `gitnexus-pr-review` | Reviewing pull requests |
| `gitnexus-cli` | Running GitNexus CLI (analyze/index repo, check status) |

**Rule:** If there is even a 1% chance a skill applies, invoke it via the `Skill` tool before doing anything else.

---

## Beads Workflow

Use **beads** for any non-trivial implementation work:

1. Convert the engineering plan (`velocityui-prompt.md`) into beads using `beads-workflow` skill
2. Polish beads multiple rounds before implementing
3. Use `br` CLI to manage beads, `bv --robot-*` flags for agent queries (never bare `bv`)
4. Each bead must be self-contained, dependency-aware, and include test criteria

**Beads CLI:**
```bash
br init                          # initialize in project
br ready --json                  # list ready (unblocked) beads
bv --robot-next                  # get top bead to work on
bv --robot-plan                  # get parallel execution tracks
bv --robot-insights              # graph analysis (bottlenecks, cycles)
```

---

## GitNexus Knowledge Graph

The GitNexus index provides structural graph context for this codebase. It is kept fresh automatically via pre-tool hooks.

### Wiki Docs

> **Note:** The GitNexus wiki for this project will be available at `.gitnexus/wiki/` once generated. Reference those docs for architecture decisions, module ownership, and dependency maps.

To regenerate the wiki:
```bash
gitnexus analyze --skills /Users/muradsabanov/Desktop/VelocityUI
```

### Graph Queries

Use GitNexus MCP tools for codebase intelligence:
- `mcp__gitnexus__query` — query the knowledge graph
- `mcp__gitnexus__impact` — impact analysis before changes
- `mcp__gitnexus__context` — get context for a symbol/file
- `mcp__gitnexus__route_map` — trace call paths

---

## Architecture Reference

Four-layer architecture (full spec in `velocityui-prompt.md`):

```
Layer 1: Developer DSL        (@MainActor, SwiftUI-like, result builders)
Layer 2: Render Pipeline      (nonisolated pure functions, TaskGroup, ring buffer)
Layer 3: Scroll Container     (@MainActor, CALayer-backed, zero async on scroll path)
Layer 4: Media Pipeline       (ImageActor, GIFActor, VideoController)
```

### Critical Invariants (never violate)
- Scroll path never awaits — `updateVisibleCells` is synchronous
- No `CATextLayer` anywhere — use `NSTextLayoutManager` → `CGImage` → plain `CALayer.contents`
- No `cornerRadius`/`masksToBounds` on `CALayer` — round at decode time via `CGContext` clip
- All images normalised to BGRA8888 premultiplied at decode time
- `NodeTable` crosses layer boundaries (no existential `any RenderNode` past Layer 1)
- `WorkingRange` is a ring buffer — never a `[Int: ResolvedLayout]` dictionary

### Build Order
```
Phase 1: Image-only vertical feed (proves all layer boundaries)
Phase 2: Text render parity (TextKit 2 measure = render within 1pt)
Phase 3: GIF support
Phase 4: Video support
Phase 5: Masonry layout
Phase 6: Hardening (os_signpost, CI frame-drop counter, accessibility v2)
```

---

## Swift Conventions

- **Swift 6**, strict concurrency throughout
- iOS 16.0 minimum
- Swift Package Manager only (no CocoaPods)
- All types crossing actor boundaries must be `Sendable`
- `@unchecked Sendable` only for pooled single-owner patterns (e.g. `TextMeasurementContext`)
- Media actors use custom `DispatchQueue`-backed executors, isolated from the cooperative pool
- No UICollectionView
- No UIView per cell

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **VelocityUI** (1655 symbols, 2384 relationships, 47 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/VelocityUI/context` | Codebase overview, check index freshness |
| `gitnexus://repo/VelocityUI/clusters` | All functional areas |
| `gitnexus://repo/VelocityUI/processes` | All execution flows |
| `gitnexus://repo/VelocityUI/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

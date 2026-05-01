# project-view — Enhanced Project Visualisation for Emacs

**A clean, single-table project browser with rich VC/Git status and VC faces.**

`project-view` displays *all* Emacs projects (from `project--list`) in one navigable vtable inside the dedicated buffer `*Project View*`. It groups projects by workspace using the variable `project-view/workspace-list` and shows the workspace basename as the first column.

---

## Features

- **Single unified table** — no more multiple per-workspace tables.
- **Workspace column** — first column shows the basename of the parent workspace directory (e.g. `github` for any project under `/Downloads/github/`).
- **Dedicated major mode** — `project-view-mode` with its own buffer `*Project View*`.
- **Precise VC face styling** (all built-in, matching `vc-dir`).
- **Full interactivity** — RET or mouse-1 on any row calls `project-switch-project`.
- **Robust workspace management** — `M-x project-view/add-workspace-directory` refuses to create a workspace nested inside an existing one.
- **Graceful fallback** — non-Git / non-VC projects and projects added outside the workspace system are handled cleanly (shown under "Other").
- **Minimal dependencies** — only built-in Emacs packages (`project`, `vc`, `vtable`, `cl-lib`).

---

## Installation & Usage

Place `project-view.el` in your load-path, `(require 'project-view)`, and run `M-x project-view`.  
RET or mouse-1 on any row calls the standard `project-switch-project`.

---

## Integration with `project.el` — Summary of Core Functions Used

`project-view` is a **read-only visualisation layer** that observes and enhances the standard `project.el` infrastructure without modifying its core behaviour:

| Emacs Function / Variable                    | Behaviour Summary                                                                                                                                                                               | How `project-view` Uses It                                                                                                        |
|----------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `project--list`                              | Canonical (internal but de-facto standard) list of known project roots. Used by `project-switch-project`, `project-remember-project`, `project-forget-project`, and `M-x project-list-buffers`. | Primary data source. All projects in this list are displayed (grouped by workspace or under "Other").                             |
| `project-remember-projects-under`            | Recursively scans a directory tree (depth-limited) and adds any Git (or other VC) project roots it finds to `project--list`.                                                                    | Called by `M-x project-view/scan-workspaces` so that workspaces populate the global project database.                             |
| `project-switch-project`                     | Prompts the user to select a project (from `project--list`), switches to it, and runs all registered hooks (`project-switch-commands`, etc.).                                                   | Invoked when the user selects a row in the `*Project View*` buffer — full behavioural compatibility is guaranteed.                |
| `project-list-file` / `user-emacs-directory` | Standard location (`~/.emacs.d/projects`) for persisting the project list.                                                                                                                      | `project-view/workspace-list` is persisted in a sibling file (`workspace-list.el`) using the same directory and Lisp-data format. |

**Key design point**: Because `project.el` itself has no native "workspace" or grouping concept, `project-view` adds `project-view/workspace-list` on top while still treating `project--list` as the single source of truth.

---

## Integration with `vc` / `vc-dir.el` — Summary of Core Functions Used

Status information is obtained **directly from the same primitives that power `M-x vc-dir`**, ensuring visual and semantic consistency:

| Emacs Function / Variable                                                                                          | Behaviour Summary                                                                                                                                                                                                     | How `project-view` Uses It                                                                                                                                               |
|--------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `vc-responsible-backend`                                                                                           | Returns the VC backend symbol (e.g. `Git`) responsible for a directory, or `nil` if none.                                                                                                                             | Detects whether a project root is under version control before attempting Git queries.                                                                                   |
| `vc-git--run-command-string`                                                                                       | Low-level helper that runs a Git command in a specific directory and returns the output as a string (handles process creation, error suppression, etc.). Used internally by all `vc-git-*` functions and by `vc-dir`. | Fetches branch, `status --porcelain`, upstream tracking branch, short commit, remote URL, and stash list — exactly the same data `vc-dir` displays.                      |
| `vc-state-base`, `vc-up-to-date-state`, `vc-needs-update-state`, `vc-dir-status-ignored`, `vc-dir-file`, `warning` | Face definitions that control colours and styling in all VC-related buffers.                                                                                                                                          | Applied to every column so that a "clean" project appears in the same colour as it does in `M-x vc-dir`, a missing upstream is highlighted with the `warning` face, etc. |
| `file-truename`, `expand-file-name`, `file-in-directory-p`, `abbreviate-file-name`                                 | Canonical, symlink-safe path utilities used throughout Emacs (including `project.el` and `vc`).                                                                                                                       | Robust workspace matching and path canonicalisation so that `~/foo`, `/home/user/foo`, and symlinked paths are treated identically.                                      |
| `truncate-string-to-width` (simple.el)                                                                             | Built-in string truncation that respects display width, handles multibyte characters, and appends an ellipsis.                                                                                                        | Replaces all previous custom `substring` + length arithmetic in `format-path`, `format-remote`, and `format-project-display`.                                            |

**Result**: The colours, information density, and status values in `*Project View*` are **identical** to what you see when you run `M-x vc-dir` on the same directory. There is no duplicated VC logic and no risk of the two views diverging.

---

## Design Decisions

- **Core Emacs only** — zero external dependencies for maximum compatibility and stability.
- **Canonical symbols preferred** — even "internal" names such as `project--list` and `vc-git--run-command-string` are used because they are the actual implementation behind the user-facing commands.
- **Custom truncation replaced** — the previous hand-written truncation logic has been removed in favour of `truncate-string-to-width`.
- **Workspace nesting prevention** — `add-workspace-directory` uses only core path functions (`file-truename`, `expand-file-name`, `file-in-directory-p`) plus `cl-find-if`.
- **Quiet by default** — all diagnostic `message` calls are now guarded by the `project-view-debug` defcustom.

---

## License

SPDX-License-Identifier: MIT

Copyright © 2026 Simon Watson

# project-view — Enhanced Project Visualisation for Emacs

**A clean, single-table project browser with rich VC/Git status and VC faces.**

`project-view` displays outermost Git projects in one navigable vtable inside the dedicated buffer `*Project View*`. It groups projects by
workspace using the variable `project-view/workspace-list`. The Project column shows the workspace basename, any intermediate subdirectory
between the workspace and the project root, and the project name.

---

## Features

- **Single unified table** — no more multiple per-workspace tables.
- **Workspace-relative Project column** — a project at `/some/path/workspace/python/my_project` is shown as `workspace/python:
  my_project`. A project that is a direct child of the workspace is shown as `workspace: my_project`.
- **Outermost Git repositories only** — a directory is a project only when it contains a `.git` entry (directory or file) and no parent
  directory is already a Git repository. Nested repos, submodules, and non-Git `project.el` markers are ignored.
- **Dedicated major mode** — `project-view-mode` with its own buffer `*Project View*`.
- **Default Emacs font** — the table uses `project-view-face` (inherits `default`) instead of `vtable`'s built-in `variable-pitch` face, so
  the buffer matches ordinary Emacs windows.
- **Precise VC face styling** (foreground/status colours from built-in `vc-dir` faces, composed with `project-view-face` so the font family
  is preserved).
- **Full interactivity** — RET or mouse-1 on any row calls `project-switch-project`.
- **Robust workspace management** — `M-x project-view/add-workspace-directory` refuses to create a workspace nested inside an existing one.
- **Ungrouped Git projects** — Git repositories that are known to Emacs but sit outside every configured workspace appear under `Other`.
- **Minimal dependencies** — only built-in Emacs packages (`project`, `vc`, `vtable`, `cl-lib`).

---

## Installation & Usage

Place `project-view.el` in your load-path, `(require 'project-view)`, and run `M-x project-view`.

1. `M-x project-view/add-workspace-directory` to register one or more workspace roots.
2. `M-x project-view/scan-workspaces` to discover outermost Git repositories under those roots and add them to `project--list`.
3. `M-x project-view` to open the table. RET or mouse-1 on any row calls the standard `project-switch-project`.

Set `project-view-debug` to a non-nil value if you need grouping or discovery traces in `*Messages*`.

---

## Project identification

`project-remember-projects-under` is **not** used for discovery. That command walks every subdirectory and asks `project.el` whether each
one is a project, so it happily records:

- non-Git roots created by `project-vc-extra-root-markers` (for example `package.json`, `pyproject.toml`);
- nested Git repositories and submodules;
- any other backend registered on `project-find-functions`.

`project-view` instead walks each workspace itself and records a directory only when all of the following hold:

1. The directory contains a `.git` entry (a directory *or* a file — worktrees use a file).
2. No ancestor directory contains a `.git` entry.
3. The walk does not descend into a directory once a Git marker has been found.

The same predicate is applied when building the table, so stale non-Git entries already sitting in `project--list` are hidden.

Depth is limited by `project-view/discover-max-depth` (default 8). Because scanning stops at the first Git root, that value only controls
how deep the walker looks for *outermost* repositories.

---

## Integration with `project.el` — Summary of Core Functions Used

`project-view` is a **read-only visualisation layer** that observes and enhances the standard `project.el` infrastructure without modifying
its core behaviour:

| Emacs Function / Variable | Behaviour Summary | How `project-view` Uses It |
|----------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `project--list` | Canonical (internal but de-facto standard) list of known project roots. Used by `project-switch-project`, `project-remember-project`, `project-forget-project`, and `M-x project-list-buffers`. | Primary data source, *filtered* to outermost Git roots. Combined with on-disk discovery under each workspace.  |
| `project-remember-project` | Adds a single project object to `project--list` and optionally writes `project-list-file`.  | Called by `M-x project-view/scan-workspaces` for each discovered outermost Git root (`(vc Git DIR)`).  |
| `project-switch-project` | Prompts the user to select a project (from `project--list`), switches to it, and runs all registered hooks (`project-switch-commands`, etc.).  | Invoked when the user selects a row in the `*Project View*` buffer — full behavioural compatibility is guaranteed.  |
| `project-list-file` / `user-emacs-directory` | Standard location (`~/.emacs.d/projects`) for persisting the project list.  | `project-view/workspace-list` is persisted in a sibling file (`workspace-list.el`) using the same directory and Lisp-data format. |

**Key design point**: Because `project.el` itself has no native "workspace" or grouping concept, `project-view` adds
`project-view/workspace-list` on top while still treating `project--list` as the known-projects database. The view is stricter than
`project.el`: it only *shows* outermost Git repositories.

---

## Integration with `vc` / `vc-dir.el` — Summary of Core Functions Used

Status information is obtained **directly from the same primitives that power `M-x vc-dir`**, ensuring visual and semantic consistency:

| Emacs Function / Variable                                                                                          | Behaviour Summary                                                                                                                                                                                                     | How `project-view` Uses It                                                                                                                          |
|--------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `vc-responsible-backend`                                                                                           | Returns the VC backend symbol (e.g. `Git`) responsible for a directory, or `nil` if none.                                                                                                                             | Detects whether a project root is under version control before attempting Git queries.                                                              |
| `vc-git--run-command-string`                                                                                       | Low-level helper that runs a Git command in a specific directory and returns the output as a string (handles process creation, error suppression, etc.). Used internally by all `vc-git-*` functions and by `vc-dir`. | Fetches branch, `status --porcelain`, upstream tracking branch, short commit, remote URL, and stash list — exactly the same data `vc-dir` displays. |
| `vc-state-base`, `vc-up-to-date-state`, `vc-needs-update-state`, `vc-dir-status-ignored`, `vc-dir-file`, `warning` | Face definitions that control colours and styling in all VC-related buffers.                                                                                                                                          | Applied *together with* `project-view-face` so status colours match `vc-dir` while the font family stays on `default`.                              |
| `file-truename`, `expand-file-name`, `file-in-directory-p`, `abbreviate-file-name`, `locate-dominating-file`       | Canonical, symlink-safe path utilities used throughout Emacs (including `project.el` and `vc`).                                                                                                                       | Workspace matching, path canonicalisation, and the “parent is already a Git repo” test.                                                             |
| `truncate-string-to-width` (simple.el)                                                                             | Built-in string truncation that respects display width, handles multibyte characters, and appends an ellipsis.                                                                                                        | Used by `format-path`, `format-remote`, and `format-project-display`.                                                                               |

**Result**: Status colours and Git values in `*Project View*` stay aligned with `M-x vc-dir`. The typeface is the user's `default` face, not
`vtable`'s `variable-pitch`.

---

## Design Decisions

- **Core Emacs only** — zero external dependencies for maximum compatibility and stability.
- **Canonical symbols preferred** — even "internal" names such as `project--list` and `vc-git--run-command-string` are used because they are
  the actual implementation behind the user-facing commands.
- **Custom truncation replaced** — hand-written truncation logic was removed in favour of `truncate-string-to-width`.
- **Workspace nesting prevention** — `add-workspace-directory` uses only core path functions (`file-truename`, `expand-file-name`,
  `file-in-directory-p`) plus `cl-find-if`.
- **Git-only, outermost-only discovery** — scanning does not call `project-remember-projects-under`, whose recursive
  `project--find-in-directory` walk is what produced directories that were not Git projects.
- **Default font, not `variable-pitch`** — `make-vtable` defaults to the `vtable` face (`:inherit variable-pitch`). `project-view` overrides
  that with `project-view-face` (`:inherit default`), remaps `vtable` and `header-line` in the buffer, and enables `buffer-face-mode`.
- **Quiet by default** — all diagnostic `message` calls are guarded by the `project-view-debug` defcustom.

---

## Customisation

| Variable / face                         | Purpose                                                                               |
|-----------------------------------------|---------------------------------------------------------------------------------------|
| `project-view/workspace-list-file`      | Where the workspace list is stored (default: `user-emacs-directory`).                 |
| `project-view/buffer-name`              | Buffer name (default `*Project View*`).                                               |
| `project-view/format-max-path-length`   | Truncation width for the Project column (default 72).                                 |
| `project-view/format-max-remote-length` | Truncation width for remote URLs (default 50).                                        |
| `project-view/discover-max-depth`       | Maximum walk depth when looking for outermost Git roots (default 8).                  |
| `project-view-debug`                    | Extra `*Messages*` tracing.                                                           |
| `project-view-face`                     | Table/buffer face. Inherits `default`. Customise this if you want a different family. |

---

## License

SPDX-License-Identifier: MIT

Copyright © 2026 Simon Watson

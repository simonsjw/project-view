# project-view — Enhanced Project Visualisation for Emacs

**A single-table project browser with cached local Git status.**

`project-view` displays outermost Git projects in one vtable inside `*Project View*`. It groups projects by `project-view/workspace-list`. The Project column shows the workspace basename, any intermediate subdirectory between the workspace and the project root, and the project name.

Git columns are painted from a cache in `user-emacs-directory` and reconciled in the background with one local `git status --porcelain=v2` per stale repository. Nothing on the display path contacts a remote.

---

## Features

- **Single unified table** grouped by workspace.
- **Workspace-relative Project column** — `/some/path/workspace/python/my_project` is shown as `workspace/python: my_project`.
- **Outermost Git repositories only** — a `.git` marker and no Git parent. Nested repos, submodules, and non-Git `project.el` markers are ignored.
- **Status cache** — `~/.emacs.d/project-view-cache.el`, keyed by canonical root. Freshness is HEAD / index / stash mtime, not wall-clock age.
- **Background refresh** — stale rows show the last snapshot immediately; one porcelain process at a time fills them in.
- **Save latch** — `after-save-hook` marks that repository dirty without running Git. Only porcelain may mark it clean again.
- **Default Emacs font** — `project-view-face` inherits `default`, not `vtable`'s `variable-pitch`.
- **RET / mouse-1** calls `project-switch-project`. `g` in the view forces a full porcelain refresh.
- **Minimal dependencies** — built-in `project`, `vc` faces, `vtable`, `cl-lib`.

---

## Files

Keep the directory that contains these files on `load-path`, then `(require 'project-view)`.

| File | Role |
|------|------|
| `project-view.el` | Loader, autoloaded `project-view` command, hook setup |
| `project-view-vars.el` | Defgroup, defcustoms, faces, shared state |
| `project-view-path.el` | Canonical paths and column formatters |
| `project-view-workspace.el` | Workspace list load / save / add / remove |
| `project-view-discover.el` | Outermost Git discovery and `scan-workspaces` |
| `project-view-git.el` | Local porcelain v2 status and Git mtimes |
| `project-view-cache.el` | Session + disk cache |
| `project-view-group.el` | Workspace grouping |
| `project-view-refresh.el` | Background worker, `g`, save / check-in hooks |
| `project-view-table.el` | Vtable, major mode, row rendering |

---

## Installation & Usage

```elisp
(add-to-list 'load-path "/path/to/project-view-dir")
(require 'project-view)
```

1. `M-x project-view/add-workspace-directory` to register workspace roots.
2. `M-x project-view/scan-workspaces` to remember outermost Git repositories.
3. `M-x project-view` to open the table.

`g` in `*Project View*` queues a porcelain refresh for every row. Set `project-view-debug` for traces.

---

## Cache

The cache file is `project-view/cache-file` (default `~/.emacs.d/project-view-cache.el`). It is lisp-data, one record per canonical root:

```elisp
(("/home/you/ws/python/my_project"
  :branch "main" :status "dirty" :upstream "origin/main"
  :commit "a1b2c3d4e5f6" :remote "git@github.com:you/my_project.git"
  :stash "Nothing stashed" :backend Git
  :mtime-head 1727800000.0 :mtime-index 1727800100.0 :mtime-stash 0
  :source porcelain)
 ...)
```

A record is reused when `:source` is `porcelain` and the three mtimes still match `.git/HEAD`, `.git/index`, and the stash ref. Writes are debounced by `project-view/cache-idle-write-seconds` (default 1.5) and flushed on `kill-emacs-hook`.

`after-save-hook` sets `:status dirty` and `:source save-hook` for the buffer's Git root. That row is shown dirty immediately and queued for porcelain confirmation.

Set `project-view/include-untracked` to `nil` if untracked walks dominate status time.

---

## Project identification

`project-remember-projects-under` is not used. Discovery records a directory only when it contains a `.git` entry (directory or file), no ancestor has a `.git`, and the walk does not descend into a Git root. The same predicate filters `project--list` when the table is built. Depth is `project-view/discover-max-depth` (default 8).

---

## Integration notes

- `project--list` is the primary project source, filtered to outermost Git roots and deduplicated by canonical path. On-disk discovery runs only when that list is empty.
- `project-remember-project` is called by `scan-workspaces` with `(vc Git DIR)`.
- Status colours still use `vc-state-base`, `vc-up-to-date-state`, `vc-needs-update-state`, and friends, composed with `project-view-face`.
- Git data comes from `git --no-optional-locks status --porcelain=v2 --branch --show-stash`, not from six `vc-git--run-command-string` calls. `remote.origin.url` is read from config only when the cache has no URL yet.

---

## Customisation

| Variable / face | Purpose |
|-----------------|---------|
| `project-view/workspace-list-file` | Workspace list path |
| `project-view/cache-file` | Status cache path |
| `project-view/cache-idle-write-seconds` | Debounce for cache writes |
| `project-view/include-untracked` | Count untracked files as dirty |
| `project-view/discover-max-depth` | Discovery walk depth |
| `project-view/format-max-path-length` | Project column truncation |
| `project-view/format-max-remote-length` | Remote column truncation |
| `project-view-debug` | Extra `*Messages*` tracing |
| `project-view-face` | Table/buffer face (`:inherit default`) |

---

## License

SPDX-License-Identifier: MIT

Copyright © 2026 Simon Watson

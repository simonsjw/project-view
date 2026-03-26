# project-view — Enhanced Project Visualization for Emacs

**A clean, single-table project browser with rich VC/Git status and VC faces.**

`project-view` displays *all* Emacs projects (from `project--list`) in one navigable vtable inside the dedicated buffer `*Project View*`. It groups projects by workspace (using the existing `my-project/workspace-list` from `project-support.el`), shows the workspace basename as the first column, and applies the exact face styling you requested.

---

## Features

- **Single unified table** — no more multiple per-workspace tables.
- **Workspace column** — first column shows the basename of the parent workspace directory (e.g. `github` for any project under `/Downloads/github/`).
- **Dedicated major mode** — `project-view-mode` with its own buffer `*Project View*`.
- **Precise VC face styling** (all built-in):
  - Entire buffer defaults to `vc-state-base`.
  - Header line uses `vc-state-base`.
  - **Path** column: `mouse-face` = `embark-target`.
  - **Status** column: `clean` → `vc-dir-up-to-date-state`, `dirty` → `vc-needs-update-state`.
  - **Upstream** column: `none` highlighted with `warning` face (orange in most themes).
  - **Commit** column: `vc-dir-status-ignored`.
  - **Remote** column: `vc-dir-file`.
- **Full interactivity** — RET or mouse-1 on any row calls `project-switch-project`.
- **Robust** — gracefully handles non-Git and non-VC projects (no errors).
- **Minimal dependencies** — only built-in Emacs packages (`project`, `vc`, `vtable`, `cl-lib`).

---

## Installation

1. Place `project-view.el` in your load path (e.g. `~/.emacs.d/lisp/` or `~/.emacs.d/site-lisp/`).
2. Add to your init file:

   ```elisp
   (require 'project-view)
   ```

   (If you are already loading `project-support.el`, it will automatically pull in `project-view`.)

3. (Optional) Bind the command to a convenient key:

   ```elisp
   (global-set-key (kbd "C-c p v") #'project-view)
   ```

---

## Usage

- `M-x project-view` — opens (or refreshes) the `*Project View*` buffer.
- Inside the buffer:
  - Click any row or press **RET** to switch to that project.
  - Use standard Emacs navigation (`n`/`p`, `C-n`/`C-p`, etc.).
  - The buffer is read-only and uses `view-mode` semantics.

The table is rebuilt fresh each time the command runs, so new projects added via `project-remember-projects-under` or workspace changes appear immediately.

---

## Customization

All variables are in the `project-view` customization group.

```elisp
M-x customize-group RET project-view RET
```

### Available options

| Variable                                | Default | Description                            |
|-----------------------------------------|---------|----------------------------------------|
| `project-view/format-max-path-length`   | 60      | Truncation limit for the Path column   |
| `project-view/format-max-remote-length` | 50      | Truncation limit for the Remote column |

Column widths are defined in `project-view/column-widths` (a plist). You may override it after loading the package if you prefer different sizing.

---

## Dependencies

- Emacs 29.1 or newer (tested with 29+ and 30+)
- Built-in packages only:
  - `project`
  - `vc` (and `vc-git`)
  - `vtable`
  - `cl-lib`

No external packages required.

---

## Integration with `project-support.el`

`project-view` re-uses the workspace list managed by your existing `project-support.el` (`my-project/workspace-list`).
If you have not yet loaded `project-support.el`, the package will gracefully fall back to showing only projects from `project--list` (ungrouped under “Other”).

---

## License

SPDX-License-Identifier: MIT

Copyright © 2026 Simon Watson

---

## Author & Credits

- Original workspace and project logic: Simon Watson
- Refactored and documented by Grok (March 2026)

```

---

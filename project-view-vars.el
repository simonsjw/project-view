;;; project-view-vars.el --- User options and shared state -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Defgroup, defcustoms, faces and shared variables for `project-view'.
;; Other modules require this file first so option symbols exist before
;; any function body refers to them.

;;; Code:

(defgroup project-view nil
  "Project visualisation buffer with cached Git status."
  :group 'projects
  :prefix "project-view-")

(defcustom project-view/format-max-path-length 72
  "Maximum length for path display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/format-max-remote-length 50
  "Maximum length for remote URL display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/discover-max-depth 8
  "Maximum subdirectory depth used when discovering Git repositories.

Scanning stops as soon as a Git repository is found, so this value only
limits how deep the walker looks for *outermost* repositories under a
workspace."
  :type 'integer
  :group 'project-view)

(defcustom project-view/buffer-name "*Project View*"
  "The name of the buffer in which the project view is displayed."
  :type 'string
  :group 'project-view)

(defcustom project-view/workspace-list-file
  (expand-file-name "workspace-list.el" user-emacs-directory)
  "File that stores `project-view/workspace-list'.

May be set before this package is loaded (for example via `defvar' in
the init file)."
  :type 'file
  :group 'project-view)

(defcustom project-view/cache-file
  (expand-file-name "project-view-cache.el" user-emacs-directory)
  "Persistent Git-status cache written under `user-emacs-directory'.

Sibling of `project-view/workspace-list-file'.  Never written into a
repository worktree, so it cannot dirty `git status'."
  :type 'file
  :group 'project-view)

(defcustom project-view/cache-idle-write-seconds 1.5
  "Idle seconds to wait before flushing `project-view/cache' to disk."
  :type 'number
  :group 'project-view)

(defcustom project-view/include-untracked t
  "When non-nil, treat untracked files as making a repository dirty.

Bound to Git's `--untracked-files=' flag.  Set to nil to skip the
untracked walk when status is the bottleneck."
  :type 'boolean
  :group 'project-view)

(defcustom project-view-debug nil
  "When non-nil, emit diagnostic messages from `project-view' functions."
  :type 'boolean
  :group 'project-view)

(defface project-view-face
  '((t :inherit default))
  "Face used for the *Project View* table and buffer.

Inherits from `default' so the view uses the same font as ordinary
Emacs buffers rather than `vtable''s `variable-pitch' face."
  :group 'project-view)

(defvar project-view/workspace-list nil
  "List of workspace root directories.
Each element is a one-element list containing the absolute directory
path, in the same format used by `project--list'.")

(defvar project-view/cache (make-hash-table :test #'equal)
  "In-memory Git-status cache keyed by canonical project root.
Each value is a plist produced by `project-view--make-cache-record'.")

(defvar project-view--cache-dirty nil
  "Non-nil when `project-view/cache' has unsaved changes.")

(defvar project-view--cache-timer nil
  "Idle timer used to flush `project-view/cache' to disk.")

(defvar project-view--refresh-queue nil
  "List of canonical project roots waiting for a porcelain refresh.")

(defvar project-view--refresh-running nil
  "Non-nil while a background Git status process is alive.")

(defvar project-view/column-widths
  '(:project 56 :branch 15 :status 8 :upstream 18
             :commit 12 :remote 50 :stash 18 :backend 8)
  "Plist of column widths for the project vtable display.")

(defvar project-view/vtable-columns
  (list
   (list :name "Project"  :width (plist-get project-view/column-widths :project)
         :align 'left)
   (list :name "Branch"   :width (plist-get project-view/column-widths :branch))
   (list :name "Status"   :width (plist-get project-view/column-widths :status))
   (list :name "Upstream" :width (plist-get project-view/column-widths :upstream))
   (list :name "Commit"   :width (plist-get project-view/column-widths :commit))
   (list :name "Remote"   :width (plist-get project-view/column-widths :remote))
   (list :name "Stash"    :width (plist-get project-view/column-widths :stash))
   (list :name "Backend"  :width (plist-get project-view/column-widths :backend)))
  "Column definitions for the vtable display.")

(provide 'project-view-vars)
;;; project-view-vars.el ends here

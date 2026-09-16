;;; project-view-discover.el --- Outermost Git repository discovery -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Walk workspace trees and remember only directories that contain a
;; `.git' marker and that are not nested inside another Git repository.
;; `project-remember-projects-under' is deliberately not used.
;;
;; Roots written to `project--list' go through `project-current' and
;; `project-view--project-list-root' so they match the abbreviated,
;; trailing-slash form `project.el' persists.  Equivalent spellings
;; already in the list are dropped first.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-workspace)

(defun project-view--git-marker-p (DIR)
  "Return non-nil if DIR is a Git working tree or repository root.

DIR is an absolute or expandable directory path.  A Git marker is
either a `.git' directory or a `.git' file (worktrees and some
submodules use a file that points at the real gitdir)."
  (let ((git (expand-file-name ".git" DIR)))
    (or (file-directory-p git)
        (file-regular-p git)
        (file-exists-p git))))

(defun project-view--ancestor-git-p (DIR)
  "Return non-nil if an ancestor of DIR is already a Git repository.

DIR is the candidate project directory.  The check starts at the parent
of DIR so that DIR's own `.git' does not count."
  (let ((parent (file-name-directory
                 (directory-file-name (expand-file-name DIR)))))
    (and parent
         (locate-dominating-file parent ".git"))))

(defun project-view--outermost-git-project-p (DIR)
  "Return non-nil if DIR is an outermost Git project root.

DIR is a directory path.  It qualifies when it contains a `.git' marker
and no parent directory is itself a Git repository."
  (and (file-directory-p DIR)
       (project-view--git-marker-p DIR)
       (not (project-view--ancestor-git-p DIR))))

(defun project-view--ignored-directory-name-p (NAME)
  "Return non-nil if directory NAME should be skipped while walking.

NAME is a single path component, not a full path.  Dot directories are
skipped so that `.git', `.venv' and similar entries are not descended
into."
  (string-prefix-p "." NAME))

(defun project-view--discover-projects-under (DIR &optional MAX-DEPTH)
  "Recursively find outermost Git project roots under DIR.

DIR is the directory to scan.  MAX-DEPTH is the maximum number of
subdirectory levels to descend (default `project-view/discover-max-depth'
or 8).  When a Git marker is found its descendants are not scanned.

Return a list of expanded project directory paths.  Paths are not
truenamed; `project-view--remember-git-project' converts each one
into the spelling `project.el' stores."
  (let ((projects nil)
        (max-depth (or MAX-DEPTH project-view/discover-max-depth 8)))
    (cl-labels
        ((walk (current depth)
           (cond
            ((not (file-directory-p current)) nil)
            ((project-view--git-marker-p current)
             (push (directory-file-name (expand-file-name current))
                   projects))
            ((> depth 0)
             (dolist (entry (directory-files
                             current t directory-files-no-dot-files-regexp t))
               (when (and (file-directory-p entry)
                          (not (project-view--ignored-directory-name-p
                                (file-name-nondirectory entry))))
                 (walk entry (1- depth))))))))
      (walk (expand-file-name DIR) max-depth))
    (nreverse projects)))

(defun project-view--vc-project-at (DIR)
  "Return the `project.el' project object for DIR, or nil.

DIR is a candidate project directory.  `project-current' is preferred
so the root string is whatever `project-try-vc' would produce.  If
that returns nothing, fall back to a VC project whose root is
`project-view--project-list-root'."
  (let ((default-directory (file-name-as-directory (expand-file-name DIR))))
    (or (project-current nil default-directory)
        (and (project-view--git-marker-p default-directory)
             (list 'vc 'Git (project-view--project-list-root DIR))))))

(defun project-view--forget-duplicate-roots (DIR)
  "Remove `project--list' entries that name the same directory as DIR.

DIR is any spelling of the project root.  Comparison uses
`project-view--same-project-root-p' so `~/proj', `/home/user/proj'
and `/home/user/proj/' collapse to one entry.  The list file is
not written; the caller persists once."
  (when (fboundp 'project--ensure-read-project-list)
    (project--ensure-read-project-list))
  (when (and (boundp 'project--list) (listp project--list))
    (setq project--list
          (seq-remove
           (lambda (ent)
             (project-view--same-project-root-p (car-safe ent) DIR))
           project--list))))

(defun project-view--remember-git-project (DIR)
  "Remember DIR as a Git project in `project--list' if it qualifies.

DIR is an absolute project directory.  Equivalent spellings already
present in `project--list' are dropped, then `project-remember-project'
is called with the object `project-current' builds.  Persistence is
deferred so the caller can flush the list once."
  (when (and (project-view--outermost-git-project-p DIR)
             (fboundp 'project-remember-project))
    (condition-case err
        (when-let* ((pr (project-view--vc-project-at DIR))
                    (root (project-root pr)))
          (project-view--forget-duplicate-roots root)
          (project-remember-project pr t))
      (error
       (when project-view-debug
         (message "project-view: remember failed for %s: %S" DIR err))))))

;;;###autoload
(defun project-view/dedupe-project-list ()
  "Collapse `project--list' entries that name the same directory.

Each surviving root is rewritten with `project-view--project-list-root'
so it matches the abbreviated, trailing-slash form `project.el'
uses after `project--read-project-list'.  The project list file is
written when anything changes."
  (interactive)
  (when (fboundp 'project--ensure-read-project-list)
    (project--ensure-read-project-list))
  (unless (and (boundp 'project--list) (listp project--list))
    (user-error "project-view: `project--list' is not loaded"))
  (let ((seen (make-hash-table :test #'equal))
        (kept nil)
        (dropped 0))
    (dolist (ent project--list)
      (let* ((root (car-safe ent))
             (normalized (and (stringp root)
                              (project-view--project-list-root root)))
             (key (and (stringp root)
                       (ignore-errors (project-view--canonical-dir root)))))
        (cond
         ((not (stringp root))
          (push ent kept))
         ((and key (gethash key seen))
          (setq dropped (1+ dropped)))
         (t
          (when key
            (puthash key t seen))
          (push (cons normalized (cdr ent)) kept)))))
    (setq project--list (nreverse kept))
    (when (and (fboundp 'project--write-project-list)
               (> dropped 0))
      (project--write-project-list))
    (message "project-view: Dropped %d duplicate project root%s."
             dropped (if (= dropped 1) "" "s"))
    dropped))

(defun project-view/scan-workspaces ()
  "Interactively scan workspace directories for outermost Git repositories.

Each directory in `project-view/workspace-list' is walked up to
`project-view/discover-max-depth' levels.  Nested repositories,
submodules and non-Git project markers are ignored.  Equivalent
`project--list' spellings are collapsed before the list is saved."
  (interactive)
  (project-view--ensure-workspace-list)
  (let ((total 0))
    (dolist (parent-dir project-view/workspace-list)
      (let* ((absolute-parent-dir (expand-file-name (car parent-dir)))
             (found (project-view--discover-projects-under
                     absolute-parent-dir
                     project-view/discover-max-depth)))
        (message "Scanning directory: %s" absolute-parent-dir)
        (dolist (proj-dir found)
          (project-view--remember-git-project proj-dir)
          (setq total (1+ total)))))
    (project-view/dedupe-project-list)
    (when (fboundp 'project--write-project-list)
      (project--write-project-list))
    (message "project-view: Remembered %d outermost Git project%s."
             total (if (= total 1) "" "s"))))

(provide 'project-view-discover)
;;; project-view-discover.el ends here

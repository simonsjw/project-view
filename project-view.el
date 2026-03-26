;;; project-view.el --- Project visualization buffer with Git status -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;; Author: Simon Watson (with assistance from Grok)
;; Keywords: projects, vc, convenience
;; Version: 0.4
;; Package-Requires: ((emacs "29.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides `project-view-mode' and the command `project-view'
;; which displays all Emacs projects (from `project--list') in a single,
;; richly formatted vtable.
;;
;; Features:
;; • Buffer *Project View* with dedicated major mode `project-view-mode'
;; • Workspace name as the first column (basename of the parent directory)
;; • All text defaults to `vc-state-base'
;; • Path column: mouse-face `embark-target'
;; • Status column: clean → `vc-up-to-date-state', dirty → `vc-needs-update-state'
;; • Upstream column: "none" coloured with `warning' face (orange in most themes)
;; • Commit column: `vc-dir-status-ignored'
;; • Remote column: `vc-dir-file'
;; • Full RET / mouse-1 support to switch projects via `project-switch-project'
;; • Depends only on built-in Emacs packages (project, vc, vtable, cl-lib)
;; • Robust handling of non-VC projects (no more errors)

;;; Code:

(require 'vtable)
(require 'cl-lib)
(require 'vc)
(require 'project)

(defgroup project-view nil
  "Project visualization buffer."
  :group 'projects
  :prefix "project-view-")

(defcustom project-view/format-max-path-length 60
  "Maximum length for path display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/format-max-remote-length 50
  "Maximum length for remote URL display before truncation."
  :type 'integer
  :group 'project-view)

(defvar project-view/column-widths
  '(:workspace 26 :path 58 :backend 8 :branch 15 :status 8 :upstream 18 :commit 12
               :remote 50 :stash 18)
  "Plist of column widths for the project vtable display.")

(defvar project-view/vtable-columns
  (list
   (list :name "Workspace" :width (plist-get project-view/column-widths :workspace) :align 'left)
   (list :name "Path"      :width (plist-get project-view/column-widths :path)     :align 'left)
   (list :name "Backend"   :width (plist-get project-view/column-widths :backend))
   (list :name "Branch"    :width (plist-get project-view/column-widths :branch))
   (list :name "Status"    :width (plist-get project-view/column-widths :status))
   (list :name "Upstream"  :width (plist-get project-view/column-widths :upstream))
   (list :name "Commit"    :width (plist-get project-view/column-widths :commit))
   (list :name "Remote"    :width (plist-get project-view/column-widths :remote))
   (list :name "Stash"     :width (plist-get project-view/column-widths :stash)))
  "Column definitions for the vtable display.")

(defun project-view/format-path (PATH)
  "Format PATH for display with truncation if necessary.

INPUT VARIABLES:
  PATH (string) - Absolute or relative path to a project directory.

EXPECTED OUTPUT / ACTION:
  Returns a possibly truncated string suitable for the Path column."
  (let ((l (length PATH)))
    (if (<= l project-view/format-max-path-length)
        PATH
      (concat (substring PATH 0 20) " ... " (substring PATH (- l 35) l)))))

(defun project-view/format-remote (REMOTE)
  "Format REMOTE URL for display with truncation if necessary.

INPUT VARIABLES:
  REMOTE (string) - URL or description of the Git remote.

EXPECTED OUTPUT / ACTION:
  Returns a possibly truncated string suitable for the Remote column."
  (if (string-match-p "^\\(no remote\\|none\\|N/A\\)$" REMOTE)
      REMOTE
    (let ((l (length REMOTE)))
      (if (<= l project-view/format-max-remote-length)
          REMOTE
        (concat (substring REMOTE 0 20) "..." (substring REMOTE (- l 35) l))))))

(defun project-view/get-canonical-pairs (DIRS)
  "Return list of (original . canonical) pairs for DIRS.

INPUT VARIABLES:
  DIRS (list of strings) - List of directory paths (workspaces or projects).

EXPECTED OUTPUT / ACTION:
  Returns a list of cons cells where car is the original path and cdr is the
  canonical (truename, absolute, directory) form."
  (mapcar (lambda (orig)
            (cons orig
                  (file-name-as-directory
                   (file-truename (expand-file-name orig)))))
          DIRS))

(defun project-view/get-grouped-projects ()
  "Group all known projects by their workspace directories.

INPUT VARIABLES:
  None.

EXPECTED OUTPUT / ACTION:
  Returns a cons cell (PROJECT-GROUPS . UNGROUPED-PROJECTS) where PROJECT-GROUPS
  is a hash table (keys = workspace original paths, values = sorted project pairs)
  and UNGROUPED-PROJECTS is a sorted list of projects that belong to no workspace."
  (let* ((workspaces-orig (progn
                            (unless (boundp 'my-project/workspace-list)
                              (ignore-errors (my-project/load-workspace-directories)))
                            (when (boundp 'my-project/workspace-list)
                              (mapcar #'car my-project/workspace-list))))
         (projects-orig (when (boundp 'project--list)
                          (mapcar #'car project--list)))
         (workspace-pairs
          (project-view/get-canonical-pairs (or workspaces-orig '())))
         (project-pairs
          (project-view/get-canonical-pairs (or projects-orig '())))
         (project-groups (make-hash-table :test 'equal))
         (ungrouped-projects nil))
    (unless (or workspaces-orig projects-orig)
      (user-error "No workspaces or projects available to display"))
    (dolist (ws-orig workspaces-orig)
      (puthash ws-orig nil project-groups))
    (dolist (proj-pair project-pairs)
      (let* ((proj-canon (cdr proj-pair))
             (matching-ws nil))
        (dolist (ws-pair workspace-pairs)
          (when (string-prefix-p (cdr ws-pair) proj-canon)
            (push ws-pair matching-ws)))
        (if matching-ws
            (let* ((best-ws-pair (car
                                  (sort matching-ws
                                        (lambda (a b) (> (length (cdr a))
                                                         (length (cdr b)))))))
                   (best-ws-orig (car best-ws-pair)))
              (puthash best-ws-orig
                       (cons proj-pair (gethash best-ws-orig project-groups))
                       project-groups))
          (push proj-pair ungrouped-projects))))
    (dolist (ws-orig workspaces-orig)
      (puthash ws-orig (sort (gethash ws-orig project-groups)
                             (lambda (a b) (string< (car a) (car b))))
               project-groups))
    (setq ungrouped-projects
          (sort ungrouped-projects (lambda (a b) (string< (car a) (car b)))))
    (cons project-groups ungrouped-projects)))

(defun project-view/git-repo-info (DIR)
  "Return Git repository information plist for DIR using built-in VC.

INPUT VARIABLES:
  DIR (string) - Absolute path to a project directory.

EXPECTED OUTPUT / ACTION:
  Returns a plist (:backend :branch :status :upstream :commit :remote :stash)
  or nil if the directory is not a Git repository (or has no VC backend at all)."
  (let ((default-directory (file-truename (expand-file-name DIR))))
    (when (eq (vc-responsible-backend default-directory t) 'Git)
      (condition-case nil
          (let* ((branch
                  (string-trim
                   (or (vc-git--run-command-string nil "rev-parse" "--abbrev-ref" "HEAD") "")))
                 (status-output
                  (vc-git--run-command-string nil "status" "--porcelain"))
                 (status
                  (if (string-empty-p (or status-output "")) "clean" "dirty"))
                 (upstream
                  (string-trim
                   (or (vc-git--run-command-string
                        nil "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{upstream}") "")))
                 (commit
                  (string-trim
                   (or (vc-git--run-command-string nil "rev-parse" "--short" "HEAD") "")))
                 (remote
                  (string-trim
                   (or (vc-git--run-command-string nil "remote" "get-url" "origin") "")))
                 (stash-output
                  (vc-git--run-command-string nil "stash" "list"))
                 (stash
                  (if (string-empty-p (or stash-output "")) "Nothing stashed" "Stashed changes exist")))
            (list :backend 'Git
                  :branch (if (string-empty-p branch) "no commits" branch)
                  :status status
                  :upstream (if (or (string-empty-p upstream) (string-match-p "fatal" upstream)) "none" upstream)
                  :commit (if (string-empty-p commit) "no commits" commit)
                  :remote (if (or (string-empty-p remote) (string-match-p "fatal" remote)) "no remote" remote)
                  :stash stash))
        (error nil)))))

(defun project-view--make-row (PROJ-PAIR WORKSPACE-NAME)
  "Create a vtable row object from a project pair and its workspace name.

INPUT VARIABLES:
  PROJ-PAIR      (cons)   - (original-path . canonical-path)
  WORKSPACE-NAME (string) - Basename of the parent workspace (or \"Other\").

EXPECTED OUTPUT / ACTION:
  Returns a plist suitable as a row for `make-vtable' with keys
  :original, :canonical, :workspace-name, and :info."
  (let ((orig (car PROJ-PAIR))
        (canon (cdr PROJ-PAIR)))
    (list :original orig
          :canonical canon
          :workspace-name WORKSPACE-NAME
          :info (project-view/git-repo-info canon))))

(defun project-view--vtable-getter (ROW COLUMN VTABLE)
  "Extract column value from ROW and apply requested VC faces.

INPUT VARIABLES:
  ROW    (plist) - Row data created by `project-view--make-row'.
  COLUMN (integer) - Column index in the vtable.
  VTABLE (vtable) - The vtable object (used to obtain column name).

EXPECTED OUTPUT / ACTION:
  Returns a propertized string for display in the vtable cell."
  (let ((info (plist-get ROW :info))
        (col-name (vtable-column VTABLE COLUMN)))
    (pcase col-name
      ("Workspace"
       (propertize (or (plist-get ROW :workspace-name) "Other") 'face 'vc-state-base))

      ("Path"
       (propertize (format "  %s" (project-view/format-path (plist-get ROW :original)))
                   'face 'vc-state-base
                   'mouse-face 'embark-target))

      ("Backend"
       (let ((backend (if info (or (plist-get info :backend) "-") "-")))
         (propertize (if (symbolp backend) (symbol-name backend) backend)
                     'face 'vc-state-base)))

      ("Branch"
       (propertize (if info (or (plist-get info :branch) "no commits") "-") 'face 'vc-state-base))

      ("Status"
       (let* ((status (if info (or (plist-get info :status) "-") "-"))
              (face (pcase status
                      ("clean" 'vc-up-to-date-state)
                      ("dirty" 'vc-needs-update-state)
                      (_ 'vc-state-base))))
         (propertize status 'face face)))

      ("Upstream"
       (let ((val (if info (or (plist-get info :upstream) "none") "none")))
         (propertize val 'face (if (string= val "none") 'warning 'vc-state-base))))

      ("Commit"
       (propertize (if info (or (plist-get info :commit) "no commits") "-")
                   'face 'vc-dir-status-ignored))

      ("Remote"
       (propertize (if info
                       (project-view/format-remote (or (plist-get info :remote) "no remote"))
                     "-")
                   'face 'vc-dir-file))

      ("Stash"
       (propertize (if info (or (plist-get info :stash) "Nothing stashed") "-")
                   'face 'vc-state-base))

      (_ (propertize "-" 'face 'vc-state-base)))))

(defun project-view--switch-to-project (ROW)
  "Switch Emacs to the project represented by ROW.

INPUT VARIABLES:
  ROW (plist) - Row data containing the :canonical project path.

EXPECTED OUTPUT / ACTION:
  Calls `project-switch-project' with the canonical path (no return value)."
  (when-let ((path (plist-get ROW :canonical)))
    (project-switch-project path)))

(define-derived-mode project-view-mode special-mode "Project View"
  "Major mode for the *Project View* buffer.

INPUT VARIABLES:
  None (standard `define-derived-mode' invocation).

EXPECTED OUTPUT / ACTION:
  Sets up buffer-local faces, header-line, read-only state and truncation.
  All text defaults to `vc-state-base'."
  :group 'project-view
  (buffer-face-set 'vc-state-base)
  (setq header-line-format (propertize " Project View" 'face 'vc-state-base))
  (setq buffer-read-only t)
  (setq truncate-lines t))

;;;###autoload
(defun project-view ()
  "Display all projects in the *Project View* buffer using a single vtable.

INPUT VARIABLES:
  None (interactive command).

EXPECTED OUTPUT / ACTION:
  Creates or re-uses the *Project View* buffer, populates it with a vtable,
  activates `project-view-mode', and switches to the buffer."
  (interactive)
  (let* ((grouped (project-view/get-grouped-projects))
         (project-groups (car grouped))
         (ungrouped-projects (cdr grouped))
         (all-rows nil))
    ;; Grouped workspaces
    (dolist (ws-orig (sort (hash-table-keys project-groups) #'string<))
      (let ((workspace-name (file-name-nondirectory (directory-file-name ws-orig))))
        (dolist (proj-pair (gethash ws-orig project-groups))
          (push (project-view--make-row proj-pair workspace-name) all-rows))))
    ;; Ungrouped projects
    (dolist (proj-pair ungrouped-projects)
      (push (project-view--make-row proj-pair "Other") all-rows))
    (setq all-rows (nreverse all-rows))
    (with-current-buffer (get-buffer-create "*Project View*")
      (let ((inhibit-read-only t))
        (erase-buffer))
      (project-view-mode)
      (make-vtable
       :columns project-view/vtable-columns
       :objects all-rows
       :getter #'project-view--vtable-getter
       :use-header-line t
       :actions '("RET" project-view--switch-to-project
                  "<mouse-1>" project-view--switch-to-project))
      (goto-char (point-min))
      (switch-to-buffer (current-buffer)))))

(provide 'project-view)
;;; project-view.el ends here

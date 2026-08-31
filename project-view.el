;;; project-view.el --- Project visualisation buffer with Git status -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;; Author: Simon Watson (with assistance from Grok)
;; Keywords: projects, vc, convenience
;; Version: 1.2
;; Package-Requires: ((emacs "29.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `project-view' displays outermost Git projects in one vtable inside
;; `*Project View*', grouped by `project-view/workspace-list'.
;;
;; A directory is a project only when it contains a `.git' entry and no
;; ancestor directory is already a Git repository.
;;
;; Git columns are served from a cache in `user-emacs-directory'
;; (`project-view-cache.el').  Fresh records are those whose stored
;; HEAD/index/stash mtimes still match the files on disk.  Stale rows
;; are painted immediately from the last snapshot and reconciled in the
;; background with one `git status --porcelain=v2' per repository.
;; Saving a file latches that repository to dirty; only porcelain may
;; mark it clean again.
;;
;; The Project column shows workspace, any intermediate subdirectory,
;; and the project name (`workspace/python: my_project').
;;
;; Files (keep the directory that contains this file on `load-path'):
;;   project-view-vars.el       options and shared state
;;   project-view-path.el       canonical paths and formatters
;;   project-view-workspace.el  workspace list persistence
;;   project-view-discover.el   outermost Git discovery
;;   project-view-git.el        local porcelain v2 status
;;   project-view-cache.el      session + disk cache
;;   project-view-group.el      workspace grouping
;;   project-view-refresh.el    background refresh and VC hooks
;;   project-view-table.el      vtable, mode, row rendering

;;; Code:

(require 'vtable)
(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-workspace)
(require 'project-view-discover)
(require 'project-view-git)
(require 'project-view-cache)
(require 'project-view-group)
(require 'project-view-refresh)
(require 'project-view-table)

(defun project-view--build-rows ()
  "Return the list of vtable row plists for the current projects."
  (let* ((grouped (condition-case err
                      (project-view/get-grouped-projects)
                    (error
                     (message "project-view ERROR in get-grouped-projects: %S" err)
                     (cons (make-hash-table :test 'equal) nil))))
         (project-groups (car grouped))
         (ungrouped-projects (cdr grouped))
         (all-rows nil))
    (dolist (ws-orig (sort (hash-table-keys project-groups) #'string<))
      (let ((workspace-name
             (file-name-nondirectory (directory-file-name ws-orig))))
        (dolist (proj-pair (gethash ws-orig project-groups))
          (push (project-view--make-row proj-pair workspace-name ws-orig)
                all-rows))))
    (dolist (proj-pair ungrouped-projects)
      (push (project-view--make-row proj-pair "Other" nil) all-rows))
    (nreverse all-rows)))

;;;###autoload
(defun project-view ()
  "Display all outermost Git projects in the *Project View* buffer.

Paint rows from the on-disk cache first.  Stale or missing Git columns
are filled in by a background porcelain worker.  RET or mouse-1 on a
row calls `project-switch-project'.  `g' forces a full refresh."
  (interactive)
  (project-view/load-cache)
  (project-view--ensure-workspace-list)
  (let ((all-rows (project-view--build-rows)))
    (with-current-buffer (get-buffer-create project-view/buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (project-view-mode)
      (if all-rows
          (let ((inhibit-read-only t))
            (make-vtable
             :columns project-view/vtable-columns
             :objects all-rows
             :getter #'project-view--vtable-getter
             :face 'project-view-face
             :use-header-line t
             :keymap project-view-mode-map
             :actions '("RET" project-view--switch-to-project
                        "<double-mouse-1>" project-view--switch-to-project)))
        (let ((inhibit-read-only t))
          (insert (propertize "\n  No Git projects found.\n\n" 'face 'warning)
                  "Run M-x project-view/scan-workspaces after adding a workspace.\n")))
      (goto-char (point-min))
      (switch-to-buffer (current-buffer)))))

(add-hook 'after-save-hook #'project-view--note-save)
(add-hook 'vc-checkin-hook #'project-view--note-checkin)
(add-hook 'kill-emacs-hook #'project-view--flush-cache)

;; Load workspaces early so interactive add/remove works before the view.
(project-view--ensure-workspace-list)

(provide 'project-view)
;;; project-view.el ends here

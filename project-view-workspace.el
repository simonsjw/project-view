;;; project-view-workspace.el --- Workspace list persistence -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Load, save, add and remove entries in `project-view/workspace-list'.
;; Nested workspaces are refused because grouping is defined against
;; workspace roots, not against an arbitrary directory tree.
;;
;; Persistence uses the same lisp-data convention as `project-list-file',
;; written to `project-view/workspace-list-file' under
;; `user-emacs-directory'.

;;; Code:

(require 'cl-lib)
(require 'project-view-vars)
(require 'project-view-path)

(defun project-view/load-workspace-directories ()
  "Load `project-view/workspace-list' from the stored file.

A missing or invalid file leaves the variable unchanged."
  (let ((workspaces-file project-view/workspace-list-file))
    (when (file-exists-p workspaces-file)
      (condition-case err
          (let ((workspaces-list
                 (with-temp-buffer
                   (insert-file-contents workspaces-file)
                   (read (current-buffer)))))
            (when (listp workspaces-list)
              (setq project-view/workspace-list workspaces-list)))
        (error
         (message "project-view: Failed to load workspace-list.el: %S" err))))))

(defun project-view/save-workspace-directories ()
  "Save the current value of `project-view/workspace-list' to file.

The file uses Emacs' project list (lisp-data) format."
  (with-temp-file project-view/workspace-list-file
    (insert ";;; -*- lisp-data -*-\n")
    (insert (format "%S" project-view/workspace-list))))

(defun project-view--ensure-workspace-list ()
  "Ensure `project-view/workspace-list' is loaded from the persistent file.

Always refresh from disk so that add/remove-workspace-directory changes
and manual edits to the file are picked up reliably."
  (when (and (boundp 'project-view/workspace-list-file)
             (stringp project-view/workspace-list-file)
             (file-exists-p project-view/workspace-list-file))
    (condition-case err
        (project-view/load-workspace-directories)
      (error
       (when project-view-debug
         (message "project-view: ensure error: %S" err))))))

(defun project-view/add-workspace-directory (DIR)
  "Add DIR as a workspace directory in Emacs' expected format.

DIR is the directory chosen interactively or passed from Lisp.  Refuse
to add a workspace that is nested inside an existing workspace directory
(checked via canonical paths to handle symlinks, `~', and trailing
slashes)."
  (interactive "DDirectory: ")
  (project-view--ensure-workspace-list)
  (let* ((expanded-dir (expand-file-name DIR))
         (existing-parent-ws
          (cl-find-if
           (lambda (ws)
             (let* ((ws-canon (project-view--canonical-dir (car ws)))
                    (dir-canon (project-view--canonical-dir expanded-dir)))
               (and (not (string= dir-canon ws-canon))
                    (file-in-directory-p dir-canon ws-canon))))
           project-view/workspace-list)))
    (if existing-parent-ws
        (let ((ws-name (file-name-nondirectory
                        (directory-file-name (car existing-parent-ws)))))
          (message "You are attempting to set up a workspace inside existing %s. This is not supported by project-view. Please create workspaces outside of any existing ones."
                   ws-name))
      (unless (member (list expanded-dir) project-view/workspace-list)
        (setq project-view/workspace-list
              (append project-view/workspace-list (list (list expanded-dir))))
        (project-view/save-workspace-directories)
        (message "Added workspace directory: %s" expanded-dir)))))

(defun project-view/remove-workspace-directory (DIR)
  "Remove DIR from `project-view/workspace-list'.

DIR is the directory path to remove.  The persistent workspace file is
updated immediately."
  (interactive "sDirectory to remove: ")
  (let ((expanded-dir (expand-file-name DIR)))
    (setq project-view/workspace-list
          (remove (list expanded-dir) project-view/workspace-list))
    (project-view/save-workspace-directories)
    (message "Removed workspace directory: %s" expanded-dir)))

(provide 'project-view-workspace)
;;; project-view-workspace.el ends here

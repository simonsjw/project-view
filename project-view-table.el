;;; project-view-table.el --- Vtable buffer and major mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Build the `*Project View*' vtable from grouped projects.  Row Git
;; columns come from `project-view--info-for', which reads the cache
;; and queues a background refresh when the record is stale.

;;; Code:

(require 'vtable)
(require 'project)
(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-cache)
(require 'project-view-group)
(require 'project-view-refresh)

(defun project-view--make-row (PROJ-PAIR WORKSPACE-NAME WORKSPACE-ORIG)
  "Create a vtable row object from a project pair and its workspace.

PROJ-PAIR is an (original . canonical) cons.  WORKSPACE-NAME is the
workspace basename (or \"Other\").  WORKSPACE-ORIG is the original
workspace directory path, or nil for ungrouped rows."
  (let ((orig (car PROJ-PAIR))
        (canon (cdr PROJ-PAIR)))
    (list :original orig
          :canonical canon
          :workspace-name WORKSPACE-NAME
          :workspace-orig WORKSPACE-ORIG
          :info (project-view--info-for canon))))

(defun project-view--apply-face (STRING FACE)
  "Return STRING propertized with FACE on top of `project-view-face'.

STRING is the cell text.  FACE is a face symbol used for colour."
  (propertize STRING 'face (list 'project-view-face FACE)))

(defun project-view--vtable-getter (ROW COLUMN VTABLE)
  "Extract the column value from ROW and apply VC faces.

ROW is the plist row data.  COLUMN is the integer column index.
VTABLE is the vtable object.  Return a propertized string."
  (let ((info (plist-get ROW :info))
        (col-name (vtable-column VTABLE COLUMN)))
    (pcase col-name
      ("Project"
       (let ((display (project-view/format-project-display
                       (plist-get ROW :workspace-orig)
                       (plist-get ROW :original)
                       (or (plist-get ROW :workspace-name) "Other"))))
         (propertize display
                     'face '(project-view-face vc-state-base)
                     'mouse-face 'highlight)))
      ("Branch"
       (project-view--apply-face
        (if info (or (plist-get info :branch) "no commits") "-")
        'vc-state-base))
      ("Status"
       (let* ((status (if info (or (plist-get info :status) "-") "-"))
              (face (pcase status
                      ("clean" 'vc-up-to-date-state)
                      ("dirty" 'vc-needs-update-state)
                      (_ 'vc-state-base))))
         (project-view--apply-face status face)))
      ("Upstream"
       (let ((val (if info (or (plist-get info :upstream) "none") "none")))
         (project-view--apply-face
          val (if (string= val "none") 'warning 'vc-state-base))))
      ("Commit"
       (project-view--apply-face
        (if info (or (plist-get info :commit) "no commits") "-")
        'vc-dir-status-ignored))
      ("Remote"
       (project-view--apply-face
        (if info (project-view/format-remote
                  (or (plist-get info :remote) "no remote"))
          "-")
        'vc-dir-file))
      ("Stash"
       (project-view--apply-face
        (if info (or (plist-get info :stash) "Nothing stashed") "-")
        'vc-state-base))
      ("Backend"
       (let ((backend (if info (or (plist-get info :backend) "-") "-")))
         (project-view--apply-face
          (if (symbolp backend) (symbol-name backend) backend)
          'vc-state-base)))
      (_ (project-view--apply-face "-" 'vc-state-base)))))

(defun project-view--switch-to-project (ROW)
  "Switch Emacs to the project represented by ROW.

ROW is the selected vtable row plist."
  (when-let ((path (plist-get ROW :canonical)))
    (project-switch-project path)))

(defvar-keymap project-view-mode-map
  :parent special-mode-map
  "g" #'project-view-refresh
  "G" #'project-view-refresh)

(defun project-view--refresh-visible-row (DIR INFO)
  "Update the visible table row for DIR with INFO.

DIR is a project root.  INFO is a Git info plist.  No-op when the
view buffer is not alive."
  (when-let ((buf (get-buffer project-view/buffer-name)))
    (with-current-buffer buf
      (when-let ((table (ignore-errors (vtable-current-table))))
        (dolist (row (vtable-objects table))
          (when (equal (project-view--canonical-dir
                        (plist-get row :canonical))
                       (project-view--canonical-dir DIR))
            (plist-put row :info INFO)
            (ignore-errors (vtable-update-object table row row))))))))

(define-derived-mode project-view-mode special-mode "Project View"
  "Major mode for the *Project View* buffer.

The buffer and table use `project-view-face'.  `g' re-runs porcelain
status for every row."
  :group 'project-view
  (setq header-line-format
        (propertize " Project View" 'face '(project-view-face vc-state-base)))
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (setq-local buffer-face-mode-face 'project-view-face)
  (buffer-face-mode 1)
  (face-remap-add-relative 'vtable 'project-view-face)
  (face-remap-add-relative 'header-line 'project-view-face))

(provide 'project-view-table)
;;; project-view-table.el ends here

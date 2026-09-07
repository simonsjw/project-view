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

(defun project-view--find-table ()
  "Return the vtable in `*Project View*', or nil.

Does not depend on point.  `vtable-current-table' only works when
point is on a row, which is not true from a process sentinel."
  (when-let ((buf (get-buffer project-view/buffer-name)))
    (with-current-buffer buf
      (or (and (fboundp 'vtable-current-table)
               (save-excursion
                 (goto-char (point-min))
                 (ignore-errors (vtable-current-table))))
          (save-excursion
            (goto-char (point-min))
            (text-property-search-forward 'vtable)
            (get-text-property (point) 'vtable))))))

(defun project-view--redraw-table ()
  "Rebuild `*Project View*' from the cache without wiping it.

Preserves point as a line/column pair.  Called from a short timer so
a burst of porcelain sentinels becomes one repaint."
  (setq project-view--redraw-timer nil)
  (when-let ((buf (get-buffer project-view/buffer-name)))
    (let ((redraw
           (lambda ()
             (let ((inhibit-read-only t)
                   (line (line-number-at-pos))
                   (col (current-column))
                   (rows (project-view--build-rows)))
               (erase-buffer)
               (if rows
                   (make-vtable
                    :columns project-view/vtable-columns
                    :objects rows
                    :getter #'project-view--vtable-getter
                    :face 'project-view-face
                    :use-header-line t
                    :keymap project-view-mode-map
                    :actions '("RET" project-view--switch-to-project
                               "<double-mouse-1>" project-view--switch-to-project))
                 (insert (propertize "\n  No Git projects found.\n\n" 'face 'warning)))
               (goto-char (point-min))
               (forward-line (1- line))
               (move-to-column col)))))
      (if-let ((win (get-buffer-window buf t)))
          (with-selected-window win
            (funcall redraw))
        (with-current-buffer buf
          (funcall redraw))))))

(defun project-view--schedule-table-redraw ()
  "Rebuild the visible table on a short timer."
  (unless project-view--redraw-timer
    (setq project-view--redraw-timer
          (run-with-timer 0.15 nil #'project-view--redraw-table))))

(defun project-view--refresh-visible-row (DIR INFO)
  "Apply INFO to the row for DIR and schedule a table rebuild.

DIR is a project root.  INFO is a Git info plist.  The objects list
is updated immediately so a later rebuild cannot miss this row.
Display is deferred: `vtable-update-object' from a process sentinel
fails unless the table is under point in a visible window of the
same width, and that error was previously swallowed."
  (when-let ((buf (get-buffer project-view/buffer-name)))
    (with-current-buffer buf
      (when-let ((table (project-view--find-table)))
        (dolist (row (vtable-objects table))
          (when (equal (project-view--canonical-dir
                        (plist-get row :canonical))
                       (project-view--canonical-dir DIR))
            (plist-put row :info INFO)))))
    (project-view--schedule-table-redraw)))


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

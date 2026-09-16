;;; project-view-refresh.el --- Background porcelain refresh and VC hooks -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; One Git porcelain process at a time.  Save hooks only latch dirty.

;;; Code:

(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-git)
(require 'project-view-cache)

(declare-function project-view--refresh-visible-row "project-view-table")

(defun project-view--queue-refresh (DIR)
  "Append DIR to the porcelain refresh queue if it is not already present.

DIR is a canonical project root."
  (let ((canon (project-view--canonical-dir DIR)))
    (unless (member canon project-view--refresh-queue)
      (setq project-view--refresh-queue
            (nconc project-view--refresh-queue (list canon))))
    (project-view--maybe-start-refresh)))

(defun project-view--maybe-start-refresh ()
  "Start a porcelain process for the next queued root if idle."
  (when (and (not project-view--refresh-running)
             project-view--refresh-queue)
    (let ((dir (pop project-view--refresh-queue)))
      (if (and (stringp dir) (file-directory-p dir))
          (project-view--start-refresh-process dir)
        (project-view--maybe-start-refresh)))))

(defun project-view--start-refresh-process (DIR)
  "Run porcelain v2 asynchronously for DIR.

DIR is a canonical project root."
  (let* ((untracked (if project-view/include-untracked "normal" "no"))
         (buf (generate-new-buffer " *project-view-git*"))
         (proc (make-process
                :name "project-view-git"
                :buffer buf
                :noquery t
                :connection-type 'pipe
                :command (list "git" "-C" DIR
                               "--no-optional-locks"
                               "status" "--porcelain=v2"
                               "--branch" "--show-stash"
                               "--ignore-submodules=dirty"
                               (concat "--untracked-files=" untracked)))))
    (setq project-view--refresh-running proc)
    (process-put proc 'project-view-dir DIR)
    (set-process-sentinel proc #'project-view--refresh-sentinel)))

(defun project-view--refresh-sentinel (PROC _EVENT)
  "Handle completion of porcelain process PROC.

PROC carries the project root in its `project-view-dir' property.
_EVENT is ignored; the process status is consulted instead."
  (when (memq (process-status PROC) '(exit signal))
    (let* ((dir (process-get PROC 'project-view-dir))
           (buf (process-buffer PROC))
           (code (process-exit-status PROC))
           (output (and (buffer-live-p buf)
                        (with-current-buffer buf (buffer-string)))))
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (setq project-view--refresh-running nil)
      (when (and dir (eq code 0) output)
        (project-view--apply-refresh dir output))
      (project-view--maybe-start-refresh))))

(defun project-view--apply-refresh (DIR OUTPUT)
  "Store porcelain OUTPUT for DIR and refresh a visible table row.

DIR is the project root.  OUTPUT is porcelain v2 stdout.  A previously
cached remote URL is reused so this path stays at one Git process."
  (let* ((info (project-view--parse-porcelain-v2 OUTPUT))
         (old (gethash (project-view--canonical-dir DIR) project-view/cache))
         (remote (or (and old (plist-get old :remote))
                     (project-view--git-remote-url DIR)
                     "no remote"))
         (mtimes (project-view--git-mtimes DIR)))
    (setq info (plist-put info :remote remote))
    (setq info (append info mtimes))
    (project-view--cache-put DIR info)
    (when (fboundp 'project-view--refresh-visible-row)
      (project-view--refresh-visible-row DIR info))))

(defun project-view--root-of-buffer ()
  "Return the Git root of `default-directory', or nil."
  (when default-directory
    (locate-dominating-file default-directory ".git")))

(defun project-view--note-save ()
  "Mark the current buffer's project dirty in the cache.

Does not run Git.  Only a later porcelain refresh may set status
back to clean."
  (when-let* ((root (project-view--root-of-buffer))
              (canon (project-view--canonical-dir root))
              (rec (copy-sequence
                    (or (gethash canon project-view/cache)
                        (list :backend 'Git)))))
    (setq rec (plist-put rec :status "dirty"))
    (setq rec (plist-put rec :source 'save-hook))
    (project-view--cache-put canon rec)
    (when (fboundp 'project-view--refresh-visible-row)
      (project-view--refresh-visible-row canon rec))))

(defun project-view--note-checkin ()
  "Invalidate cached status after a VC check-in.

Does not assume the repository is clean.  Queues a porcelain refresh."
  (when-let ((root (project-view--root-of-buffer)))
    (when-let ((rec (gethash (project-view--canonical-dir root)
                             project-view/cache)))
      (setq rec (plist-put (copy-sequence rec) :source 'commit-hook))
      (project-view--cache-put root rec))
    (project-view--queue-refresh root)))

;;;###autoload
(defun project-view-refresh ()
  "Re-run porcelain status for every row in `*Project View*'.
Ignores cache freshness.  Processes run one at a time."
  (interactive)
  (when-let ((buf (get-buffer project-view/buffer-name)))
    (with-current-buffer buf
      (when-let ((table (ignore-errors (vtable-current-table))))
        (dolist (row (vtable-objects table))
          (when-let ((canon (plist-get row :canonical)))
            (project-view--queue-refresh canon))))))
  (message "project-view: refresh queued"))

(provide 'project-view-refresh)
;;; project-view-refresh.el ends here

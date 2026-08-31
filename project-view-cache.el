;;; project-view-cache.el --- Persistent Git-status cache -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Session and disk cache keyed by canonical project root.  Stored under
;; `user-emacs-directory', never inside a worktree.  A record is fresh
;; when its stored HEAD/index/stash mtimes still match the files on disk
;; and `:source' is `porcelain'.

;;; Code:

(require 'pp)
(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-git)

(defun project-view/load-cache ()
  "Load `project-view/cache' from `project-view/cache-file'.

A missing or unreadable file leaves an empty hash table.  Keys that no
longer name a directory are dropped."
  (clrhash project-view/cache)
  (when (file-exists-p project-view/cache-file)
    (condition-case err
        (let ((data (with-temp-buffer
                      (insert-file-contents project-view/cache-file)
                      (read (current-buffer)))))
          (when (listp data)
            (dolist (entry data)
              (let ((root (car entry)))
                (when (and (stringp root) (file-directory-p root))
                  (puthash (project-view--canonical-dir root)
                           (cdr entry)
                           project-view/cache))))))
      (error
       (message "project-view: Failed to load cache: %S" err)))))

(defun project-view/save-cache ()
  "Write `project-view/cache' to `project-view/cache-file'."
  (let ((entries nil))
    (maphash (lambda (root rec)
               (push (cons root rec) entries))
             project-view/cache)
    (setq entries (sort entries (lambda (a b)
                                  (string< (car a) (car b)))))
    (with-temp-file project-view/cache-file
      (insert ";;; -*- lisp-data -*-\n")
      (pp entries (current-buffer)))))

(defun project-view--flush-cache ()
  "Persist `project-view/cache' if it has unsaved changes."
  (when project-view--cache-dirty
    (project-view/save-cache)
    (setq project-view--cache-dirty nil)
    (setq project-view--cache-timer nil)))

(defun project-view--schedule-cache-write ()
  "Write the cache on a short idle timer if it has pending changes."
  (unless project-view--cache-timer
    (setq project-view--cache-timer
          (run-with-idle-timer project-view/cache-idle-write-seconds
                               nil #'project-view--flush-cache))))

(defun project-view--cache-put (DIR RECORD)
  "Store RECORD for DIR and mark the cache file unsaved.

DIR is a project root.  RECORD is a plist of Git columns plus mtimes."
  (puthash (project-view--canonical-dir DIR) RECORD project-view/cache)
  (setq project-view--cache-dirty t)
  (project-view--schedule-cache-write))

(defun project-view--cache-fresh-p (RECORD MTIMES)
  "Return non-nil if RECORD's stored mtimes equal MTIMES.

RECORD is a cache plist.  MTIMES is the plist from
`project-view--git-mtimes'.  Only porcelain-sourced records can be
fresh; a save-hook latch must be confirmed by Git."
  (and (eq (plist-get RECORD :source) 'porcelain)
       (= (or (plist-get RECORD :mtime-head) -1)
          (plist-get MTIMES :mtime-head))
       (= (or (plist-get RECORD :mtime-index) -1)
          (plist-get MTIMES :mtime-index))
       (= (or (plist-get RECORD :mtime-stash) -1)
          (plist-get MTIMES :mtime-stash))))

(defun project-view--info-for (DIR)
  "Return Git info for DIR, preferring a fresh cache record.

DIR is the project root.  A matching cache record is returned at
once.  A stale or missing record still returns whatever we last knew
\(or a placeholder) and queues a background porcelain refresh."
  (let* ((canon (project-view--canonical-dir DIR))
         (cached (gethash canon project-view/cache))
         (now (project-view--git-mtimes canon)))
    (cond
     ((and cached (project-view--cache-fresh-p cached now))
      cached)
     (t
      (when (fboundp 'project-view--queue-refresh)
        (project-view--queue-refresh canon))
      (or cached (project-view--placeholder-info))))))

(provide 'project-view-cache)
;;; project-view-cache.el ends here

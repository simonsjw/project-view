;;; project-view-path.el --- Path canonicalisation and column formatting -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Canonical path helpers and display formatters.  Duplicate rows are
;; avoided by comparing `file-truename' results with no trailing slash.

;;; Code:

(require 'project-view-vars)

(defun project-view--canonical-dir (DIR)
  "Return DIR as an absolute, symlink-resolved directory path.

DIR is a directory string.  The result has no trailing slash, so
`/home/user/proj', `/home/user/proj/' and `~/proj' compare equal
after canonicalisation."
  (directory-file-name (file-truename (expand-file-name DIR))))

(defun project-view--unique-dirs (DIRS)
  "Return DIRS with duplicates removed by canonical path.

DIRS is a list of directory strings.  The first occurrence of each
canonical path is kept so that `project--list' spellings such as
`~/proj' and `/home/user/proj/' do not become two table rows."
  (let ((seen (make-hash-table :test #'equal))
        (unique nil))
    (dolist (dir DIRS)
      (when (and (stringp dir)
                 (file-directory-p (expand-file-name dir)))
        (let ((canon (project-view--canonical-dir dir)))
          (unless (gethash canon seen)
            (puthash canon t seen)
            (push dir unique)))))
    (nreverse unique)))

(defun project-view--get-canonical-pairs (DIRS)
  "Return list of (original . canonical) pairs for DIRS.

DIRS is a list of directory strings.  Each canonical path is an
absolute, symlink-resolved directory name with a trailing slash.
Duplicate originals that collapse to the same canonical path are
dropped."
  (mapcar (lambda (orig)
            (cons orig
                  (file-name-as-directory
                   (project-view--canonical-dir orig))))
          (project-view--unique-dirs DIRS)))

(defun project-view/format-path (PATH)
  "Format PATH for display using `truncate-string-to-width'.

PATH is the raw path string.  Truncation length is controlled by
`project-view/format-max-path-length'."
  (truncate-string-to-width PATH project-view/format-max-path-length
                            nil nil "..."))

(defun project-view/format-remote (REMOTE)
  "Format REMOTE URL for display using `truncate-string-to-width'.

REMOTE is the remote URL or a placeholder such as \"no remote\".
Special-case strings like \"no remote\" are returned unchanged."
  (if (string-match-p "^\\(no remote\\|none\\|N/A\\|—\\)$" REMOTE)
      REMOTE
    (truncate-string-to-width REMOTE project-view/format-max-remote-length
                              nil nil "...")))

(defun project-view/format-project-display (WS-ORIG PROJ-ORIG WS-NAME)
  "Format the Project column for a project living under a workspace.

WS-ORIG is the original workspace directory path.  PROJ-ORIG is the
original project directory path.  WS-NAME is the workspace basename
used as the leading label (or \"Other\" when the project is ungrouped).

When PROJ-ORIG sits in a subdirectory of WS-ORIG the intermediate
relative path is included.  A project at
`/some/path/workspace/python/my_project' is shown as
`workspace/python: my_project'."
  (let* ((proj-name (file-name-nondirectory
                     (directory-file-name PROJ-ORIG)))
         (display
          (cond
           ((or (not WS-ORIG) (string= WS-NAME "Other"))
            (format "%s: %s" WS-NAME proj-name))
           (t
            (let* ((ws-canon (file-name-as-directory
                              (file-truename (expand-file-name WS-ORIG))))
                   (proj-canon (file-truename (expand-file-name PROJ-ORIG)))
                   (proj-parent (file-name-as-directory
                                 (file-name-directory
                                  (directory-file-name proj-canon))))
                   (rel (condition-case nil
                            (directory-file-name
                             (file-relative-name proj-parent ws-canon))
                          (error "."))))
              (if (or (string= rel ".") (string= rel "./")
                      (string-empty-p rel)
                      (file-name-absolute-p rel))
                  (format "%s: %s" WS-NAME proj-name)
                (format "%s/%s: %s" WS-NAME rel proj-name)))))))
    (truncate-string-to-width display project-view/format-max-path-length
                              nil nil "...")))

(provide 'project-view-path)
;;; project-view-path.el ends here

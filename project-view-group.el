;;; project-view-group.el --- Group projects by workspace -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Match each known outermost Git project to the most specific workspace
;; root.  `project--list' is the primary source; on-disk discovery is
;; used only when that list contributes no qualifying projects.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project-view-vars)
(require 'project-view-path)
(require 'project-view-workspace)
(require 'project-view-discover)

(defun project-view--find-matching-workspace (PROJ-CANON WORKSPACE-PAIRS)
  "Return the most specific matching workspace for PROJ-CANON or nil.

PROJ-CANON is the canonical project directory.  WORKSPACE-PAIRS is a
list of (original . canonical) workspace conses, already sorted with
the longest (most specific) paths first."
  (when project-view-debug
    (message "project-view: proj-canon = %s" PROJ-CANON))
  (let ((proj-variants (list PROJ-CANON
                             (file-truename PROJ-CANON)
                             (expand-file-name PROJ-CANON)
                             (abbreviate-file-name PROJ-CANON))))
    (or
     (cl-loop for ws-pair in WORKSPACE-PAIRS
              for ws-canon = (cdr ws-pair)
              when (cl-some (lambda (p) (file-in-directory-p p ws-canon))
                            proj-variants)
              return (car ws-pair))
     (progn
       (when project-view-debug
         (message "project-view: NO MATCH for proj=%s"
                  (file-name-nondirectory
                   (directory-file-name PROJ-CANON))))
       nil))))

(defun project-view--build-project-groups (PROJECT-PAIRS WORKSPACE-PAIRS)
  "Group PROJECT-PAIRS by WORKSPACE-PAIRS and return groups plus ungrouped.

PROJECT-PAIRS is a list of (original . canonical) project pairs.
WORKSPACE-PAIRS is a list of workspace pairs sorted most-specific
first.  Return (project-groups-hash . ungrouped-list)."
  (let ((project-groups (make-hash-table :test 'equal))
        (ungrouped-projects nil)
        (matched-count 0))
    (dolist (proj-pair PROJECT-PAIRS)
      (let ((matched-ws (project-view--find-matching-workspace
                         (cdr proj-pair) WORKSPACE-PAIRS)))
        (if matched-ws
            (progn
              (setq matched-count (1+ matched-count))
              (puthash matched-ws
                       (cons proj-pair (gethash matched-ws project-groups))
                       project-groups))
          (push proj-pair ungrouped-projects))))
    (when project-view-debug
      (message "project-view: Matched: %d / %d  Ungrouped: %d"
               matched-count (length PROJECT-PAIRS)
               (length ungrouped-projects)))
    (cons project-groups ungrouped-projects)))

(defun project-view--sort-groups (PROJECT-GROUPS UNGROUPED-PROJECTS)
  "Sort projects inside groups and the ungrouped list alphabetically.

PROJECT-GROUPS is a hash table keyed by workspace original path.
UNGROUPED-PROJECTS is a list of project pairs.  Return
(sorted-groups-hash . sorted-ungrouped-list)."
  (maphash (lambda (ws-orig projects)
             (puthash ws-orig
                      (sort projects (lambda (a b)
                                       (string< (car a) (car b))))
                      PROJECT-GROUPS))
           PROJECT-GROUPS)
  (cons PROJECT-GROUPS
        (sort UNGROUPED-PROJECTS (lambda (a b)
                                   (string< (car a) (car b))))))

(defun project-view--collect-candidate-projects (WORKSPACES-ORIG)
  "Collect and filter candidate project directories.

WORKSPACES-ORIG is a list of original workspace directory strings.
Prefer qualifying entries from `project--list'.  Fall back to on-disk
discovery only when that list contributes nothing.  Candidates are
restricted to outermost Git repositories and deduplicated by
canonical path."
  (let* ((from-list (seq-filter
                     #'project-view--outermost-git-project-p
                     (or (when (and (boundp 'project--list)
                                    (listp project--list))
                           (mapcar #'car project--list))
                         '())))
         (from-disk (when (null from-list)
                      (apply #'append
                             (mapcar (lambda (ws-dir)
                                       (project-view--discover-projects-under
                                        ws-dir
                                        project-view/discover-max-depth))
                                     (or WORKSPACES-ORIG '())))))
         (merged (append from-list (or from-disk '()))))
    (project-view--unique-dirs
     (seq-filter #'project-view--outermost-git-project-p merged))))

(defun project-view/get-grouped-projects ()
  "Group all known outermost Git projects by workspace.

Return (project-groups-hash . ungrouped-projects-list)."
  (project-view--ensure-workspace-list)
  (let* ((workspaces-orig (when (and (boundp 'project-view/workspace-list)
                                     (listp project-view/workspace-list))
                            (mapcar #'car project-view/workspace-list)))
         (projects-orig (project-view--collect-candidate-projects
                         workspaces-orig))
         (workspace-pairs (sort (project-view--get-canonical-pairs
                                 (or workspaces-orig '()))
                                (lambda (a b)
                                  (> (length (cdr a)) (length (cdr b))))))
         (project-pairs (project-view--get-canonical-pairs
                         (or projects-orig '())))
         (grouped (project-view--build-project-groups
                   project-pairs workspace-pairs)))
    (project-view--sort-groups (car grouped) (cdr grouped))))

(provide 'project-view-group)
;;; project-view-group.el ends here

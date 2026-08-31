;;; project-view.el --- Project visualisation buffer with Git status -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;; Author: Simon Watson (with assistance from Grok)
;; Keywords: projects, vc, convenience
;; Version: 1.1.1
;; Package-Requires: ((emacs "29.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides `project-view-mode' and the command `project-view'
;; which displays projects from `project--list' (or on-disk discovery as
;; fallback) grouped by your `project-view/workspace-list' directories.
;;
;; A directory is treated as a project only when it contains a `.git'
;; entry (directory or file) and no ancestor directory is already a Git
;; repository.  Nested repositories and submodules are therefore ignored.
;;
;; Grouping uses robust multi-strategy canonical path comparison to handle
;; ~/ vs /home/user, symlinks, trailing slashes, and similar path variants.
;;
;; The Project column shows the workspace basename, any intermediate
;; subdirectory path between the workspace and the project root, and the
;; project directory name.  For example a project at
;; `/some/path/workspace/python/my_project' is shown as
;; `workspace/python: my_project'.
;;
;; The table uses the `default' face (via `project-view-face') so the
;; buffer matches ordinary Emacs windows rather than `vtable''s built-in
;; `variable-pitch' face.

;;; Code:

(require 'vtable)
(require 'cl-lib)
(require 'seq)
(require 'vc)
(require 'vc-git)
(require 'project)

(defgroup project-view nil
  "Project visualisation buffer."
  :group 'projects
  :prefix "project-view-")

(defcustom project-view/format-max-path-length 72
  "Maximum length for path display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/format-max-remote-length 50
  "Maximum length for remote URL display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/discover-max-depth 8
  "Maximum subdirectory depth used when discovering Git repositories.

Scanning stops as soon as a Git repository is found, so this value only
limits how deep the walker looks for *outermost* repositories under a
workspace."
  :type 'integer
  :group 'project-view)

(defcustom project-view/buffer-name
  "*Project View*"
  "The name of the buffer in which the project view is displayed."
  :type 'string
  :group 'project-view)

(defcustom project-view/workspace-list-file
  (expand-file-name "workspace-list.el" user-emacs-directory)
  "File name of the workspace list for project-view.
This variable may be set by the user before this package is loaded
\(e.g. via `defconst' or `defvar' in the init file)."
  :type 'string
  :group 'project-view)

(defcustom project-view-debug nil
  "When non-nil, enable extra diagnostic messages in `project-view' functions."
  :type 'boolean
  :group 'project-view)

(defface project-view-face
  '((t :inherit default))
  "Face used for the *Project View* table and buffer.

Inherits from `default' so the view uses the same font as ordinary
Emacs buffers.  `make-vtable' otherwise defaults to the `vtable' face,
which inherits `variable-pitch' and commonly renders as a proportional
serif (or a generic sans) distinct from the configured Emacs font."
  :group 'project-view)

(defvar project-view/workspace-list nil
  "List of workspace root directories.
Each element is a one-element list containing the absolute directory path,
in the same format used by `project--list'.")

(defvar project-view/column-widths
  '(:project 56 :branch 15 :status 8 :upstream 18
             :commit 12 :remote 50 :stash 18 :backend 8)
  "Plist of column widths for the project vtable display.")

(defvar project-view/vtable-columns
  (list
   (list :name "Project"   :width
         (plist-get project-view/column-widths :project) :align 'left)
   (list :name "Branch"    :width
         (plist-get project-view/column-widths :branch))
   (list :name "Status"    :width
         (plist-get project-view/column-widths :status))
   (list :name "Upstream"  :width
         (plist-get project-view/column-widths :upstream))
   (list :name "Commit"    :width
         (plist-get project-view/column-widths :commit))
   (list :name "Remote"    :width
         (plist-get project-view/column-widths :remote))
   (list :name "Stash"     :width
         (plist-get project-view/column-widths :stash))
   (list :name "Backend"   :width
         (plist-get project-view/column-widths :backend)))
  "Column definitions for the vtable display.")


;;;; Workspace Functions
;;   -------------------
;; Functions to manage a list of workspaces and their project components.
;; These functions use variables `project-view/workspace-list' and
;; `project-view/workspace-list-file'.  These variables provide the list of
;; workspaces and the location of the file which stores those workspaces to
;; disk.
;;
;; Functions are:
;;;;; project-view/load-workspace-directories
;; Load the workspace directories file to `project-view/workspace-list'.
;;
;;;;; project-view/scan-workspaces
;; Scan for outermost Git repositories in the workspace directories
;; defined in `project-view/workspace-list'.
;;
;;;;; project-view/save-workspace-directories
;; Save the workspace directories defined in `project-view/workspace-list'
;; to disk.
;;
;;;;; project-view/add-workspace-directory
;; Add the selected workspace directory to `project-view/workspace-list'
;; and save to disk.
;;
;;;;; project-view/remove-workspace-directory
;; Remove the selected workspace directory from `project-view/workspace-list'
;; and save changes to disk.

(defun project-view/load-workspace-directories ()
  "Load `project-view/workspace-list' from the stored file.

Robustly handles a missing or invalid file by leaving the variable
unchanged."
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

(defun project-view/scan-workspaces ()
  "Interactively scan workspace directories for outermost Git repositories.

Each directory in `project-view/workspace-list' is walked up to
`project-view/discover-max-depth' levels.  Only directories that contain
a `.git' entry and that are not nested inside another Git repository are
remembered via `project-remember-project'.  Nested repositories,
submodules, and non-Git project markers are ignored."
  (interactive)
  (project-view--ensure-workspace-list)
  (let ((total 0))
    (dolist (parent-dir project-view/workspace-list)
      (let* ((absolute-parent-dir (file-truename (car parent-dir)))
             (found (project-view--discover-projects-under
                     absolute-parent-dir
                     project-view/discover-max-depth)))
        (when project-view-debug
          (message "project-view: Scanning directory: %s (%d git roots)"
                   absolute-parent-dir (length found)))
        (unless project-view-debug
          (message "Scanning directory: %s" absolute-parent-dir))
        (dolist (proj-dir found)
          (project-view--remember-git-project proj-dir)
          (setq total (1+ total)))))
    (when (fboundp 'project--write-project-list)
      (project--write-project-list))
    (message "project-view: Remembered %d outermost Git project%s."
             total (if (= total 1) "" "s"))))

(defun project-view/save-workspace-directories ()
  "Save the current value of `project-view/workspace-list' to file.

The file uses Emacs' project list (lisp-data) format."
  (with-temp-file project-view/workspace-list-file
    (insert ";;; -*- lisp-data -*-\n")
    (insert (format "%S" project-view/workspace-list))))

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
             (let* ((ws-orig (car ws))
                    (ws-canon (file-truename (expand-file-name ws-orig)))
                    (dir-canon (file-truename expanded-dir)))
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


;;;; Project-view implementation
;;   ---------------------------
;; Code used to implement the consolidated view of projects by the
;; workspace that contains them.

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
  (if (string-match-p "^\\(no remote\\|none\\|N/A\\)$" REMOTE)
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
`/some/path/workspace/python/my_project' is therefore shown as
`workspace/python: my_project'.  A project that is a direct child of
the workspace is shown as `workspace: my_project'."
  (let* ((proj-name (file-name-nondirectory
                     (directory-file-name PROJ-ORIG)))
         (display
          (cond
           ((or (not WS-ORIG)
                (string= WS-NAME "Other"))
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
              (if (or (string= rel ".")
                      (string= rel "./")
                      (string-empty-p rel)
                      (file-name-absolute-p rel))
                  (format "%s: %s" WS-NAME proj-name)
                (format "%s/%s: %s" WS-NAME rel proj-name)))))))
    (truncate-string-to-width display project-view/format-max-path-length
                              nil nil "...")))

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

;; Ensure workspaces are loaded even if the view is not active.
(project-view--ensure-workspace-list)

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
of DIR so that DIR's own `.git' does not count.  `locate-dominating-file'
walks up the tree looking for a `.git' entry."
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

NAME is a single path component, not a full path.  Dot directories
(other than `.' / `..', which `directory-files' already drops when
asked) are skipped so that `.git', `.venv', and similar entries are
not descended into."
  (string-prefix-p "." NAME))

(defun project-view--discover-projects-under (DIR &optional MAX-DEPTH)
  "Recursively find outermost Git project roots under DIR.

DIR is the directory to scan.  MAX-DEPTH is the maximum number of
subdirectory levels to descend (default `project-view/discover-max-depth'
or 8).  A directory is recorded as a project only when it contains a
`.git' entry.  When such a directory is found its descendants are not
scanned, so nested repositories and submodules are excluded.

Return a list of absolute, truename'd project directory paths."
  (let ((projects nil)
        (max-depth (or MAX-DEPTH project-view/discover-max-depth 8)))
    (cl-labels
        ((walk (current depth)
           (cond
            ((not (file-directory-p current)) nil)
            ((project-view--git-marker-p current)
             ;; Outermost Git root: record it and do not walk children.
             (push (directory-file-name (file-truename current)) projects))
            ((> depth 0)
             (dolist (entry (directory-files current t directory-files-no-dot-files-regexp t))
               (when (and (file-directory-p entry)
                          (not (project-view--ignored-directory-name-p
                                (file-name-nondirectory entry))))
                 (walk entry (1- depth))))))))
      (walk (expand-file-name DIR) max-depth))
    (nreverse projects)))

(defun project-view--remember-git-project (DIR)
  "Remember DIR as a Git project in `project--list' if it qualifies.

DIR is an absolute project directory.  Uses the standard
`(vc Git DIR)' project object understood by `project.el'.  Persistence
is deferred (`NO-WRITE') so the caller can flush the list once."
  (when (and (project-view--outermost-git-project-p DIR)
             (fboundp 'project-remember-project))
    (condition-case err
        (project-remember-project (list 'vc 'Git DIR) t)
      (error
       (when project-view-debug
         (message "project-view: remember failed for %s: %S" DIR err))))))

(defun project-view--find-matching-workspace (PROJ-CANON WORKSPACE-PAIRS)
  "Return the most specific matching workspace for PROJ-CANON or nil.

PROJ-CANON is the canonical project directory.  WORKSPACE-PAIRS is a
list of (original . canonical) workspace conses, already sorted with
the longest (most specific) paths first.

Uses several normalisation strategies to handle `~' vs `/home/user',
symlinks, trailing slashes, and similar path variants."
  (when project-view-debug
    (message "project-view: proj-canon = %s" PROJ-CANON)
    (message "project-view: workspace-pairs = %S" WORKSPACE-PAIRS))
  (let ((proj-variants (list PROJ-CANON
                             (file-truename PROJ-CANON)
                             (expand-file-name PROJ-CANON)
                             (abbreviate-file-name PROJ-CANON))))
    (or
     (cl-loop for ws-pair in WORKSPACE-PAIRS
              for ws-canon = (cdr ws-pair)
              when (cl-some (lambda (p)
                              (when project-view-debug
                                (message "base comparison\n---------------")
                                (message "project-view: p = %s" p)
                                (message "project-view: ws-canon = %s" ws-canon))
                              (file-in-directory-p p ws-canon))
                            proj-variants)
              do (when project-view-debug
                   (message "project-view:   MATCHED proj=%s -> ws=%s"
                            (file-name-nondirectory
                             (directory-file-name PROJ-CANON))
                            (file-name-nondirectory
                             (directory-file-name (car ws-pair)))))
              and return (car ws-pair))
     (progn
       (when project-view-debug
         (message "project-view:   NO MATCH for proj=%s (tried %d ws)"
                  (file-name-nondirectory (directory-file-name PROJ-CANON))
                  (length WORKSPACE-PAIRS)))
       nil))))

(defun project-view--build-project-groups (PROJECT-PAIRS WORKSPACE-PAIRS)
  "Group PROJECT-PAIRS by WORKSPACE-PAIRS and return groups plus ungrouped.

PROJECT-PAIRS is a list of (original . canonical) project pairs.
WORKSPACE-PAIRS is a list of workspace pairs sorted most-specific
first.

Return (project-groups-hash . ungrouped-list)."
  (let ((project-groups (make-hash-table :test 'equal))
        (ungrouped-projects nil)
        (matched-count 0))
    (dolist (proj-pair PROJECT-PAIRS)
      (let* ((proj-canon (cdr proj-pair))
             (matched-ws (project-view--find-matching-workspace
                          proj-canon WORKSPACE-PAIRS)))
        (if matched-ws
            (progn
              (setq matched-count (1+ matched-count))
              (puthash matched-ws
                       (cons proj-pair (gethash matched-ws project-groups))
                       project-groups))
          (push proj-pair ungrouped-projects))))
    (when project-view-debug
      (message "project-view: === GROUPING SUMMARY ===")
      (message "project-view: Matched: %d / %d projects"
               matched-count (length PROJECT-PAIRS))
      (message "project-view: Ungrouped: %d" (length ungrouped-projects)))
    (cons project-groups ungrouped-projects)))

(defun project-view--sort-groups (PROJECT-GROUPS UNGROUPED-PROJECTS)
  "Sort projects inside groups and the ungrouped list alphabetically.

PROJECT-GROUPS is a hash table keyed by workspace original path.
UNGROUPED-PROJECTS is a list of project pairs.

Return (sorted-groups-hash . sorted-ungrouped-list)."
  (maphash (lambda (ws-orig projects)
             (puthash ws-orig
                      (sort projects (lambda (a b)
                                       (string< (car a) (car b))))
                      PROJECT-GROUPS))
           PROJECT-GROUPS)
  (setq UNGROUPED-PROJECTS
        (sort UNGROUPED-PROJECTS (lambda (a b)
                                   (string< (car a) (car b)))))
  (cons PROJECT-GROUPS UNGROUPED-PROJECTS))

(defun project-view--collect-candidate-projects (WORKSPACES-ORIG)
  "Collect and filter candidate project directories.

WORKSPACES-ORIG is a list of original workspace directory strings.
Prefer qualifying entries from `project--list'.  Fall back to on-disk
discovery under each workspace only when that list contributes
nothing.  Candidates are then restricted to outermost Git repositories
and deduplicated by canonical path.

Appending both sources without canonical comparison is what produced
duplicate rows: `project--list' typically stores a path such as
`/home/user/ws/proj/' while discovery returns the truename without a
trailing slash, so `delete-dups' treated them as distinct."
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

Return (project-groups-hash . ungrouped-projects-list).  Only
directories that contain a `.git' marker and that are not nested inside
another Git repository are included."
  (when project-view-debug
    (message "project-view: get-grouped-projects START (workspaces bound=%s)"
             (boundp 'project-view/workspace-list)))
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
                   project-pairs workspace-pairs))
         (project-groups (car grouped))
         (ungrouped-projects (cdr grouped)))
    (when project-view-debug
      (message "project-view: === WORKSPACES ===")
      (message "project-view: workspaces-orig: %S" workspaces-orig)
      (message "project-view: workspace-pairs (first 3): %S"
               (seq-take workspace-pairs 3))
      (message "project-view: === PROJECTS (first 8) ===")
      (message "project-view: projects-orig (first 8): %S"
               (seq-take projects-orig 8))
      (message "project-view: Found %d workspaces and %d projects total"
               (length workspaces-orig) (length projects-orig))
      (message "project-view: ungrouped count: %d, grouped keys: %S"
               (length ungrouped-projects)
               (hash-table-keys project-groups)))
    (project-view--sort-groups project-groups ungrouped-projects)))

(defun project-view/git-repo-info (DIR)
  "Return Git repository information plist for DIR using built-in VC.

DIR is the project directory path.  Return a plist of Git info, or nil
if DIR is not a Git repository or a Git command fails."
  (let ((default-directory (file-truename (expand-file-name DIR))))
    (when (eq (vc-responsible-backend default-directory t) 'Git)
      (condition-case nil
          (let* ((branch (string-trim
                          (or (vc-git--run-command-string
                               nil "rev-parse" "--abbrev-ref" "HEAD")
                              "")))
                 (status-output (vc-git--run-command-string
                                 nil "status" "--porcelain"))
                 (status (if (string-empty-p
                              (or status-output ""))
                             "clean" "dirty"))
                 (upstream (string-trim
                            (or (vc-git--run-command-string
                                 nil "rev-parse" "--abbrev-ref"
                                 "--symbolic-full-name" "@{upstream}")
                                "")))
                 (commit (string-trim
                          (or (vc-git--run-command-string
                               nil "rev-parse" "--short" "HEAD")
                              "")))
                 (remote (string-trim
                          (or (vc-git--run-command-string
                               nil "remote" "get-url" "origin")
                              "")))
                 (stash-output (vc-git--run-command-string
                                nil "stash" "list"))
                 (stash (if (string-empty-p (or stash-output ""))
                            "Nothing stashed" "Stashed changes exist")))
            (list :branch (if (string-empty-p branch) "no commits" branch)
                  :status status
                  :upstream (if (or (string-empty-p upstream)
                                    (string-match-p "fatal" upstream))
                                "none" upstream)
                  :commit (if (string-empty-p commit) "no commits" commit)
                  :remote (if (or (string-empty-p remote)
                                  (string-match-p "fatal" remote))
                              "no remote" remote)
                  :stash stash
                  :backend 'Git))
        (error nil)))))

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
          :info (project-view/git-repo-info canon))))

(defun project-view--apply-face (STRING FACE)
  "Return STRING propertized with FACE on top of `project-view-face'.

STRING is the cell text.  FACE is a face symbol used for colour or
semantic styling (for example `vc-up-to-date-state').  Listing
`project-view-face' first keeps the table on the `default' font family
instead of inheriting a serif or variable-pitch family from FACE."
  (propertize STRING 'face (list 'project-view-face FACE)))

(defun project-view--vtable-getter (ROW COLUMN VTABLE)
  "Extract the column value from ROW and apply VC faces.

ROW is the plist row data.  COLUMN is the integer column index.
VTABLE is the vtable object.  Return a propertized string for display."
  (let ((info (plist-get ROW :info))
        (col-name (vtable-column VTABLE COLUMN)))
    (pcase col-name
      ("Project"
       (let* ((ws-name (or (plist-get ROW :workspace-name) "Other"))
              (ws-orig (plist-get ROW :workspace-orig))
              (orig (plist-get ROW :original))
              (display (project-view/format-project-display
                        ws-orig orig ws-name)))
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
          val
          (if (string= val "none") 'warning 'vc-state-base))))
      ("Commit"
       (project-view--apply-face
        (if info (or (plist-get info :commit) "no commits") "-")
        'vc-dir-status-ignored))
      ("Remote"
       (project-view--apply-face
        (if info
            (project-view/format-remote
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

ROW is the selected vtable row plist.  Call `project-switch-project'
on the canonical path."
  (when-let ((path (plist-get ROW :canonical)))
    (project-switch-project path)))

(define-derived-mode project-view-mode special-mode "Project View"
  "Major mode for the *Project View* buffer.

The buffer and table use `project-view-face', which inherits from
`default', so the font matches ordinary Emacs windows instead of the
`variable-pitch' face that `vtable' applies by default."
  :group 'project-view
  (setq header-line-format
        (propertize " Project View" 'face '(project-view-face vc-state-base)))
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (setq-local buffer-face-mode-face 'project-view-face)
  (buffer-face-mode 1)
  (face-remap-add-relative 'vtable 'project-view-face)
  (face-remap-add-relative 'header-line 'project-view-face))

;;;###autoload
(defun project-view ()
  "Display all outermost Git projects in the *Project View* buffer.

Build a single vtable grouped by workspace.  The Project column shows
the workspace basename plus any intermediate subdirectory between the
workspace and the project root.  RET or mouse-1 on a row calls
`project-switch-project'."
  (interactive)
  (when project-view-debug
    (message "project-view DEBUG: project-view command START"))
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
    (setq all-rows (nreverse all-rows))
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
             :actions '("RET" project-view--switch-to-project
                        "<double-mouse-1>" project-view--switch-to-project)))
        (let ((inhibit-read-only t))
          (insert (propertize "\n  No Git projects found.\n\n" 'face 'warning)
                  "Run M-x project-view/scan-workspaces after adding a workspace.\n")))
      (goto-char (point-min))
      (switch-to-buffer (current-buffer)))))

(provide 'project-view)
;;; project-view.el ends here

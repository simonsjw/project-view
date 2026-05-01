;;; project-view.el --- Project visualisation buffer with Git status -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;; Author: Simon Watson (with assistance from Grok)
;; Keywords: projects, vc, convenience
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides `project-view-mode' and the command `project-view'
;; which displays projects from `project--list' (or on-disk discovery as fallback)
;; grouped by your `project-view/workspace-list' directories.
;;
;; Grouping uses robust multi-strategy canonical path comparison to handle
;; ~/ vs /home/simon, symlinks, etc.  This fixes the long-standing "Other" issue
;; while still preferring the standard Emacs `project--list'.

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

(defcustom project-view/format-max-path-length 60
  "Maximum length for path display before truncation."
  :type 'integer
  :group 'project-view)

(defcustom project-view/format-max-remote-length 50
  "Maximum length for remote URL display before truncation."
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

(defvar project-view/workspace-list nil
  "List of workspace root directories.
Each element is a one-element list containing the absolute directory path,
in the same format used by `project--list'.")

(defvar project-view/column-widths
  '(:project 48 :branch 15 :status 8 :upstream 18
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
         (plist-get project-view/column-widths :backend))
   )
  "Column definitions for the vtable display.")



;;;; Workspace Functions
;;   -------------------
;;Functions to manage a list of work-spaces and their project components.
;; These functions use variables `project-view/workspace-list' and
;; `project-view/workspace-list-file'. These variables provide the list of
;; work-spaces and the location of the file which stores those work-spaces to
;; disk.

;; Functions are:
;;;;; project-view/load-workspace-directories
;; Load the workspace directories file to `project-view/workspace-list'.

;;;;; project-view/scan-work-spaces
;; Scan for projects in the the workspace directories defined
;; in `project-view/workspace-list'.

;;;;; project-view/save-workspace-directories
;; Save the workspace directories defined in `project-view/workspace-list'
;; to disk.

;;;;; project-view/add-workspace-directory
;; Add the selected workspace directory to `project-view/workspace-list'
;; and save to disk.

;;;;; project-view/remove-workspace-directory
;; Remove the selected workspace directory from `project-view/workspace-list'
;; and save changes to disk.



(defun project-view/load-workspace-directories ()
  "Load `project-view/workspace-list' from the stored file.
Robustly handles missing/invalid files by leaving the variable unchanged."
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
  "Interactively scan for new projects.

The list of directories in `project-view/workspace-list' will be scanned
recursively for projects."
  (interactive)

  (mapc (lambda (parent-dir)
          (let ((absolute-parent-dir (file-truename (car parent-dir))))
            (message "Scanning directory: %s" absolute-parent-dir)
            (project-remember-projects-under absolute-parent-dir 1)))
        project-view/workspace-list))

(defun project-view/save-workspace-directories ()
  "Save the current value of `project-view/workspace-list' to file.

The file uses Emacs' project list format."
  (with-temp-file project-view/workspace-list-file
    (insert ";;; -*- lisp-data -*-\n")
    (insert (format "%S" project-view/workspace-list))))

(defun project-view/add-workspace-directory (dir)
  "Add DIR as a project directory in Emacs' expected format.

Prevent adding a workspace that is nested inside an existing workspace
directory (checked via canonical paths to handle symlinks, ~, etc.)."
  (interactive "DDirectory: ")
  (project-view--ensure-workspace-list)
  (let* ((expanded-dir (expand-file-name dir))
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

(defun project-view/remove-workspace-directory (dir)
  "Remove DIR from `project-view/workspace-list'."
  (interactive "sDirectory to remove: ")
  (let ((expanded-dir (expand-file-name dir)))
    (setq project-view/workspace-list
          (remove (list expanded-dir) project-view/workspace-list))
    (project-view/save-workspace-directories)
    (message "Removed workspace directory: %s" expanded-dir)))



;;;; Project-view implementation
;;   ---------------------------
;; Here we have the code directly used in implementing the consolidated view
;; of projects by the work-space that contains them.

(defun project-view/format-path (path)
  "Format PATH for display using the core `truncate-string-to-width' function.
This replaces the previous custom substring logic with an Emacs built-in."
  (truncate-string-to-width path project-view/format-max-path-length
                            nil nil "..."))

(defun project-view/format-remote (remote)
  "Format REMOTE URL for display using the core `truncate-string-to-width' function.
Special-case strings like \"no remote\" are returned unchanged."
  (if (string-match-p "^\\(no remote\\|none\\|N/A\\)$" remote)
      remote
    (truncate-string-to-width remote project-view/format-max-remote-length
                              nil nil "...")))

(defun project-view/format-project-display (ws proj-name)
  "Format WS: PROJ-NAME for the Project column using `truncate-string-to-width'.
This provides consistent truncation with the rest of the display."
  (let ((s (format "%s: %s" ws proj-name)))
    (truncate-string-to-width s project-view/format-max-path-length
                              nil nil "...")))

(defun project-view--get-canonical-pairs (DIRS)
  "Return list of (original . canonical) pairs for DIRS.

INPUT VARIABLES:
  DIRS (list) - List of directory strings.

EXPECTED OUTPUT / ACTION:
  Returns list of cons cells with original and canonicalised paths."
  (mapcar (lambda (orig)
            (cons orig
                  (file-name-as-directory
                   (file-truename (expand-file-name orig)))))
          DIRS))

(defun project-view--ensure-workspace-list ()
  "Ensure `project-view/workspace-list' is loaded from the persistent file if it exists.
This always refreshes from disk so that add/remove-workspace-directory changes
and manual edits to the file are picked up reliably."
  (when (and (boundp 'project-view/workspace-list-file)
             (stringp project-view/workspace-list-file)
             (file-exists-p project-view/workspace-list-file))
    (condition-case err
        (project-view/load-workspace-directories)
      (error
       (when project-view-debug
         (message "project-view: ensure error: %S" err))))))

;; ensure workspaces are loaded even if view is not active. 
(project-view--ensure-workspace-list)


(defun project-view--discover-projects-under (dir &optional max-depth)
  "Recursively find Git project roots under DIR (up to MAX-DEPTH levels deep).
Returns a list of absolute project directory paths that contain a .git/ subdirectory.
This is used as the primary source of projects so that workspace grouping always works,
independent of whether `project--list' has been populated."
  (let ((projects nil)
        (max-depth (or max-depth 5))
        (entries (directory-files dir t "^[^.]" t)))  ; skip dotfiles/dirs for speed
    (dolist (entry entries)
      (when (file-directory-p entry)
        (if (file-directory-p (expand-file-name ".git" entry))
            (push entry projects)
          (when (> max-depth 1)
            (setq projects
                  (append projects
                          (project-view--discover-projects-under entry (1- max-depth))))))))
    projects))

(defun project-view--find-matching-workspace (proj-canon workspace-pairs)
  "Return the most specific matching workspace for PROJ-CANON or nil.
Uses multiple normalization strategies to handle ~ vs /home/simon, symlinks,
trailing slashes, etc."
  (when project-view-debug
    (message "project-view: proj-canon = %s" proj-canon)
    (message "project-view: workspace-pairs = %S" workspace-pairs))

  (let ((matched-ws nil)
        (proj-variants (list proj-canon
                             (file-truename proj-canon)
                             (expand-file-name proj-canon)
                             (abbreviate-file-name proj-canon))))
    (dolist (ws-pair workspace-pairs matched-ws)
      (let ((ws-canon (cdr ws-pair)))
        (when (cl-some (lambda (p)
                         (when project-view-debug
                           (message "base comparison\n---------------")
                           (message "project-view: p = %s" p)
                           (message "project-view: ws-canon = %s" ws-canon))
                         (file-in-directory-p p ws-canon))
                       proj-variants)
          (setq matched-ws (car ws-pair))
          (when project-view-debug
            (message "project-view:   MATCHED proj=%s -> ws=%s"
                     (file-name-nondirectory (directory-file-name proj-canon))
                     (file-name-nondirectory (directory-file-name (car ws-pair)))))
          (cl-return))))
    (unless matched-ws
      (when project-view-debug
        (message "project-view:   NO MATCH for proj=%s (tried %d ws)"
                 (file-name-nondirectory (directory-file-name proj-canon))
                 (length workspace-pairs))))
    matched-ws))

(defun project-view--build-project-groups (project-pairs workspace-pairs)
  "Group PROJECT-PAIRS by WORKSPACE-PAIRS and return groups + ungrouped.

INPUT VARIABLES:
  PROJECT-PAIRS (list) - List of (orig . canon) project pairs.
  WORKSPACE-PAIRS (list) - Sorted workspace pairs.

EXPECTED OUTPUT / ACTION:
  Returns (project-groups-hash . ungrouped-list)."
  (let ((project-groups (make-hash-table :test 'equal))                           ; hash for O(1) workspace lookup
        (ungrouped-projects nil)
        (matched-count 0))
    (dolist (proj-pair project-pairs)
      (let* ((proj-canon (cdr proj-pair))
             (matched-ws (project-view--find-matching-workspace
                          proj-canon workspace-pairs)))
        (if matched-ws
            (progn
              (setq matched-count (1+ matched-count))
              (puthash matched-ws
                       (cons proj-pair (gethash matched-ws project-groups))
                       project-groups))
          (push proj-pair ungrouped-projects))))
    (when project-view-debug
      (message "project-view: === GROUPING SUMMARY ===")
      (message "project-view: Matched: %d / %d projects" matched-count (length project-pairs))
      (message "project-view: Ungrouped: %d" (length ungrouped-projects)))
    (cons project-groups ungrouped-projects)))

(defun project-view--sort-groups (project-groups ungrouped-projects)
  "Sort projects inside groups and ungrouped list alphabetically.

INPUT VARIABLES:
  PROJECT-GROUPS (hash-table) - Groups by workspace.
  UNGROUPED-PROJECTS (list) - Ungrouped project pairs.

EXPECTED OUTPUT / ACTION:
  Returns (sorted-groups-hash . sorted-ungrouped-list)."
  (maphash (lambda (ws-orig projects)
             (puthash ws-orig
                      (sort projects (lambda (a b)
                                       (string< (car a) (car b))))
                      project-groups))
           project-groups)
  (setq ungrouped-projects
        (sort ungrouped-projects (lambda (a b)
                                   (string< (car a) (car b)))))
  (cons project-groups ungrouped-projects))

(defun project-view/get-grouped-projects ()
  "Group all known projects by their workspace directories (most specific first).

INPUT VARIABLES:
  None.

EXPECTED OUTPUT / ACTION:
  Returns (project-groups-hash . ungrouped-projects-list)."
  (when project-view-debug
    (message "project-view: get-grouped-projects START (workspaces bound=%s)"
             (boundp 'project-view/workspace-list)))
  (project-view--ensure-workspace-list)
  (let* ((workspaces-orig (when (and (boundp 'project-view/workspace-list)
                                     (listp project-view/workspace-list))
                            (mapcar #'car project-view/workspace-list)))
         ;; Primary source: `project--list' (your preference). Fallback to
         ;; on-disk discovery only if `project--list' is empty.
         (projects-orig (or (when (and (boundp 'project--list)
                                       (listp project--list))
                              (mapcar #'car project--list))
                            (apply #'append
                                   (mapcar (lambda (ws-dir)
                                             (project-view--discover-projects-under ws-dir 5))
                                           (or workspaces-orig '())))))
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
      (message "project-view: workspace-pairs (first 3): %S" (seq-take workspace-pairs 3))
      (message "project-view: === PROJECTS (first 8) ===")
      (message "project-view: projects-orig (first 8): %S" (seq-take projects-orig 8))
      (message "project-view: Found %d workspaces and %d projects total"
               (length workspaces-orig) (length projects-orig))
      (message "project-view: ungrouped count: %d, grouped keys: %S"
               (length ungrouped-projects)
               (hash-table-keys project-groups)))
    (project-view--sort-groups project-groups ungrouped-projects)))

(defun project-view/git-repo-info (DIR)
  "Return Git repository information plist for DIR using built-in VC.

INPUT VARIABLES:
  DIR (string) - Project directory path.

EXPECTED OUTPUT / ACTION:
  Returns plist of Git info or nil if not a Git repo."
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

(defun project-view--make-row (PROJ-PAIR WORKSPACE-NAME)
  "Create a vtable row object from a project pair and its workspace name.

INPUT VARIABLES:
  PROJ-PAIR (cons) - (original . canonical) pair.
  WORKSPACE-NAME (string) - Workspace basename.

EXPECTED OUTPUT / ACTION:
  Returns plist row for vtable."
  (let ((orig (car PROJ-PAIR))
        (canon (cdr PROJ-PAIR)))
    (list :original orig
          :canonical canon
          :workspace-name WORKSPACE-NAME
          :info (project-view/git-repo-info canon))))

(defun project-view--vtable-getter (ROW COLUMN VTABLE)
  "Extract column value from ROW and apply requested VC faces.

INPUT VARIABLES:
  ROW (plist) - Row data.
  COLUMN (integer) - Column index.
  VTABLE (vtable) - The vtable object.

EXPECTED OUTPUT / ACTION:
  Returns propertised string for display."
  (let ((info (plist-get ROW :info))
        (col-name (vtable-column VTABLE COLUMN)))
    (pcase col-name
      ("Project"
       (let* ((ws (or (plist-get ROW :workspace-name) "Other"))
              (orig (plist-get ROW :original))
              (proj-name (file-name-nondirectory (directory-file-name orig)))
              (display (project-view/format-project-display ws proj-name)))
         (propertize display 'face 'vc-state-base
                     'mouse-face 'embark-target)))
      ("Branch"
       (propertize (if info (or (plist-get info :branch) "no commits") "-")
                   'face 'vc-state-base))
      ("Status"
       (let* ((status (if info (or (plist-get info :status) "-") "-"))
              (face (pcase status
                      ("clean" 'vc-up-to-date-state)
                      ("dirty" 'vc-needs-update-state)
                      (_ 'vc-state-base))))
         (propertize status 'face face)))
      ("Upstream"
       (let ((val (if info (or (plist-get info :upstream) "none") "none")))
         (propertize val 'face (if (string= val "none")
                                   'warning 'vc-state-base))))
      ("Commit"
       (propertize (if info (or (plist-get info :commit) "no commits") "-")
                   'face 'vc-dir-status-ignored))
      ("Remote"
       (propertize (if info
                       (project-view/format-remote
                        (or (plist-get info :remote) "no remote"))
                     "-")
                   'face 'vc-dir-file))
      ("Stash"
       (propertize (if info (or (plist-get info :stash) "Nothing stashed") "-")
                   'face 'vc-state-base))
      ("Backend"
       (let ((backend (if info (or (plist-get info :backend) "-") "-")))
         (propertize (if (symbolp backend) (symbol-name backend) backend)
                     'face 'vc-state-base)))
      
      (_ (propertize "-" 'face 'vc-state-base)))))

(defun project-view--switch-to-project (ROW)
  "Switch Emacs to the project represented by ROW.

INPUT VARIABLES:
  ROW (plist) - Selected row data.

EXPECTED OUTPUT / ACTION:
  Calls `project-switch-project' on the canonical path."
  (when-let ((path (plist-get ROW :canonical)))
    (project-switch-project path)))

(define-derived-mode project-view-mode special-mode "Project View"
  "Major mode for the *Project View* buffer."
  :group 'project-view
  (setq header-line-format (propertize " Project View" 'face 'vc-state-base))
  (setq buffer-read-only t)
  (setq truncate-lines t))

;;;###autoload
(defun project-view ()
  "Display all projects in the *Project View* buffer using a single vtable.

INPUT VARIABLES:
  None.

EXPECTED OUTPUT / ACTION:
  Creates or refreshes `*Project View*' buffer with grouped project table."
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
    (dolist (ws-orig (sort (hash-table-keys project-groups) #'string<))           ; sort work-spaces for stable display
      (let ((workspace-name
             (file-name-nondirectory (directory-file-name ws-orig))))
        (dolist (proj-pair (gethash ws-orig project-groups))
          (push (project-view--make-row proj-pair workspace-name) all-rows))))
    (dolist (proj-pair ungrouped-projects)
      (push (project-view--make-row proj-pair "Other") all-rows))
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
             :use-header-line t
             :actions '("RET" project-view--switch-to-project
                        "<double-mouse-1>" project-view--switch-to-project)))

        (let ((inhibit-read-only t))
          (insert (propertize "\n  No projects found.\n\n" 'face 'warning)
                  "Run M-x project-view/scan-workspaces first.\n")))
      (goto-char (point-min))
      (switch-to-buffer (current-buffer)))))

(provide 'project-view)
;;; project-view.el ends here

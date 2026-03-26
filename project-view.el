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
;; which displays all Emacs projects (from `project--list') in a single,
;; richly formatted vtable.  It groups projects by workspace directories
;; (from `project-view/workspace-list' if present).
;;
;; Also provided are a set of functions to create and manage `work-spaces'
;; - directories in which projects are grouped on disk.
;;
;; The projects clustered here are integrated with those present in project.el
;; variable `project--list'.  Any projects present in `project-list' which
;; are were not found using the mechanism in project-view are assigned to
;; workspace `other'.  Thus this package fully integrates with standard
;; package.el mechanics.  This means that the package is also dependent on the
;; implementation of `project--list' in the existing Emacs setup.

;;; Code:

(require 'vtable)
(require 'cl-lib)
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

(defvar project-view-debug nil
  "When non-nil, enable extra debug messages in `project-view' functions.")

(defvar project-view/column-widths
  '(:workspace 26 :path 58  :branch 15 :status 8 :upstream 18
               :commit 12 :remote 50 :stash 18 :backend 8)
  "Plist of column widths for the project vtable display.")

(defvar project-view/vtable-columns
  (list
   (list :name "Workspace" :width
         (plist-get project-view/column-widths :workspace) :align 'left)
   (list :name "Path"      :width
         (plist-get project-view/column-widths :path) :align 'left)
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
  "Load `project-view/workspace-list' from the stored file."
  (let* ((workspaces-file project-view/workspace-list-file)
         (workspaces-list (when (file-exists-p workspaces-file)
                            (with-temp-buffer
                              (insert-file-contents workspaces-file)
                              (read (current-buffer))))))

    (setq project-view/workspace-list workspaces-list)))


(defun project-view/scan-workspaces ()
  "Interactively scan for new projects.

The list of directories in `project-view/workspace-list' will be scanned
recursively for projects."
  (interactive)

  (mapc (lambda (parent-dir)
          (let ((absolute-parent-dir (file-truename (car parent-dir))))
            ;; Process the directory string here.
            (log/info :fn 'project-view/scan-workspaces
                      :msg "Scanning directory:"
                      :obj absolute-parent-dir)
            (project-remember-projects-under absolute-parent-dir 1)))
        project-view/workspace-list))

(defun project-view/save-workspace-directories ()
  "Save the current value of `project-view/workspace-list' to file.

The file uses Emacs' project list format."
  (with-temp-file project-view/workspace-list-file
    (insert ";;; -*- lisp-data -*-\n")
    (insert (format "%S" project-view/workspace-list))))

(defun project-view/add-workspace-directory (dir)
  "Add DIR as a project directory in Emacs' expected format."
  (interactive "DDirectory: ")
  (let ((expanded-dir (expand-file-name dir)))
    (unless (member (list expanded-dir) project-view/workspace-list)
      (setq project-view/workspace-list
            (append project-view/workspace-list (list (list expanded-dir)))))
    (project-view/save-workspace-directories)
    (message "Added workspace directory: %s" expanded-dir)))

(defun project-view/remove-workspace-directory (dir)
  "Remove DIR from `project-view/workspace-list'."
  (interactive "sDirectory to remove: ")
  (let ((expanded-dir (expand-file-name dir)))
    (setq project-view/workspace-directories
          (remove (list expanded-dir) project-view/workspace-directories))
    (project-view/save-workspace-directories)
    (message "Removed workspace directory: %s" expanded-dir)))



;;;; Project-view implementation
;;   ---------------------------
;; Here we have the code directly used in implementing the consolidated view
;; of projects by the work-space that contains them.

(defun project-view/format-path (PATH)
  "Format PATH for display with truncation if necessary.

INPUT VARIABLES:
  PATH (string) - Absolute or relative path to a project directory.

EXPECTED OUTPUT / ACTION:
  Returns a possibly truncated string suitable for the Path column."
  (let ((l (length PATH)))                                                        ; compute length once for efficiency
    (if (<= l project-view/format-max-path-length)
        PATH
      (concat (substring PATH 0 20) " ... " (substring PATH (- l 35) l)))))

(defun project-view/format-remote (REMOTE)
  "Format REMOTE URL for display with truncation if necessary.

INPUT VARIABLES:
  REMOTE (string) - URL or description of the Git remote.

EXPECTED OUTPUT / ACTION:
  Returns a possibly truncated string suitable for the Remote column."
  (if (string-match-p "^\\(no remote\\|none\\|N/A\\)$" REMOTE)
      REMOTE
    (let ((l (length REMOTE)))                                                    ; reuse length for truncation logic
      (if (<= l project-view/format-max-remote-length)
          REMOTE
        (concat (substring REMOTE 0 20) "..." (substring REMOTE (- l 35) l))))))

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
  "Ensure `project-view/workspace-list' is loaded if the support file exists.

INPUT VARIABLES:
  None.

EXPECTED OUTPUT / ACTION:
  Loads workspace list if available; does nothing otherwise."
  (unless (boundp 'project-view/workspace-list)
    (ignore-errors
      (when (fboundp 'project-view/load-workspace-directories)
        (project-view/load-workspace-directories)))))

(defun project-view--find-matching-workspace (proj-canon workspace-pairs)
  "Return the most specific matching workspace for PROJ-CANON or nil.

INPUT VARIABLES:
  PROJ-CANON (string) - Canonical project path.
  WORKSPACE-PAIRS (list) - Sorted list of (orig . canon) workspace pairs.

EXPECTED OUTPUT / ACTION:
  Returns matching workspace original name or nil."
  (let ((matched-ws nil))
    (dolist (ws-pair workspace-pairs matched-ws)                                  ; most-specific-first order guarantees early exit
      (when (file-in-directory-p proj-canon (cdr ws-pair))
        (setq matched-ws (car ws-pair))
        (cl-return)))))                                                           ; early exit for efficiency

(defun project-view--build-project-groups (project-pairs workspace-pairs)
  "Group PROJECT-PAIRS by WORKSPACE-PAIRS and return groups + ungrouped.

INPUT VARIABLES:
  PROJECT-PAIRS (list) - List of (orig . canon) project pairs.
  WORKSPACE-PAIRS (list) - Sorted workspace pairs.

EXPECTED OUTPUT / ACTION:
  Returns (project-groups-hash . ungrouped-list)."
  (let ((project-groups (make-hash-table :test 'equal))                           ; hash for O(1) workspace lookup
        (ungrouped-projects nil))
    (dolist (proj-pair project-pairs)
      (let* ((proj-canon (cdr proj-pair))                                         ; bind first to avoid void-variable
             (matched-ws (project-view--find-matching-workspace
                          proj-canon workspace-pairs)))
        (if matched-ws
            (puthash matched-ws
                     (cons proj-pair (gethash matched-ws project-groups))
                     project-groups)
          (push proj-pair ungrouped-projects))))                                  ; push is more idiomatic than setq+cons
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
    (message "project-view: get-grouped-projects START"))
  (project-view--ensure-workspace-list)
  (let* ((workspaces-orig (when (and (boundp 'project-view/workspace-list)
                                     (listp project-view/workspace-list))
                            (mapcar #'car project-view/workspace-list)))
         (projects-orig (when (and (boundp 'project--list)
                                   (listp project--list))
                          (mapcar #'car project--list)))
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
      (message "project-view: Found %d workspaces and %d projects"
               (length workspaces-orig) (length projects-orig)))
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
      ("Workspace"
       (propertize (or (plist-get ROW :workspace-name) "Other")
                   'face 'vc-state-base))
      ("Path"
       (propertize (format "  %s" (project-view/format-path
                                   (plist-get ROW :original)))
                   'face 'vc-state-base
                   'mouse-face 'embark-target))
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
  (buffer-face-set '(:family "Source Code Pro" :height 100 :weight regular))
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
  (message "project-view DEBUG: project-view command START")
  (let* ((grouped (project-view/get-grouped-projects))
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
                        "<mouse-1>" project-view--switch-to-project)))
        (let ((inhibit-read-only t))
          (insert (propertize "\n  No projects found.\n\n" 'face 'warning)
                  "Run M-x project-view/scan-workspaces first.\n")))
      (goto-char (point-min))
      (switch-to-buffer (current-buffer)))))

(provide 'project-view)
;;; project-view.el ends here

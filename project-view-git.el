;;; project-view-git.el --- Local Git status via porcelain v2 -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Simon Watson
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A single `git status --porcelain=v2 --branch --show-stash' replaces
;; the previous six `vc-git--run-command-string' calls.  Nothing here
;; contacts a remote.

;;; Code:

(require 'project-view-vars)
(require 'project-view-path)

(defun project-view--mtime (FILE)
  "Return FILE's modification time as a float, or 0 if FILE is absent.

FILE is an absolute path."
  (if (file-exists-p FILE)
      (float-time (file-attribute-modification-time
                   (file-attributes FILE)))
    0))

(defun project-view--git-dir (DIR)
  "Return the Git directory for working tree DIR, or nil.

DIR is a project root.  Handles both a `.git' directory and a `.git'
file used by worktrees."
  (let ((git (expand-file-name ".git" DIR)))
    (cond
     ((file-directory-p git) git)
     ((file-readable-p git)
      (with-temp-buffer
        (insert-file-contents git)
        (when (looking-at "gitdir:[[:space:]]*\\(.*\\)$")
          (expand-file-name (string-trim (match-string 1)) DIR))))
     (t nil))))

(defun project-view--git-mtimes (DIR)
  "Return a plist of Git metadata mtimes for DIR.

DIR is the project root.  Missing files yield 0 so a later appearance
of a stash ref is visible as a change."
  (let ((git-dir (project-view--git-dir DIR)))
    (if (not git-dir)
        (list :mtime-head 0 :mtime-index 0 :mtime-stash 0)
      (list :mtime-head  (project-view--mtime (expand-file-name "HEAD" git-dir))
            :mtime-index (project-view--mtime (expand-file-name "index" git-dir))
            :mtime-stash (let ((a (project-view--mtime
                                   (expand-file-name "logs/refs/stash" git-dir)))
                               (b (project-view--mtime
                                   (expand-file-name "refs/stash" git-dir))))
                           (if (> a b) a b))))))

(defun project-view--parse-porcelain-v2 (OUTPUT)
  "Parse porcelain v2 OUTPUT into the row plist `project-view' uses.

OUTPUT is the raw stdout of
`git status --porcelain=v2 --branch --show-stash'."
  (let ((branch nil)
        (oid nil)
        (upstream "none")
        (stash "Nothing stashed")
        (dirty nil))
    (dolist (line (split-string OUTPUT "\n" t))
      (cond
       ((string-prefix-p "# branch.head " line)
        (setq branch (substring line 14)))
       ((string-prefix-p "# branch.oid " line)
        (setq oid (substring line 13)))
       ((string-prefix-p "# branch.upstream " line)
        (setq upstream (substring line 18)))
       ((string-prefix-p "# stash " line)
        (setq stash "Stashed changes exist"))
       ((not (string-prefix-p "#" line))
        (setq dirty t))))
    (list :branch (if (or (not branch)
                          (string= branch "(detached)")
                          (string-empty-p branch))
                      "no commits" branch)
          :status (if dirty "dirty" "clean")
          :upstream (if (string-empty-p upstream) "none" upstream)
          :commit (if (and oid (not (string= oid "(initial)")))
                      (substring oid 0 (min 12 (length oid)))
                    "no commits")
          :remote "no remote" :stash stash :backend 'Git :source 'porcelain)))

(defun project-view--git-remote-url (DIR)
  "Return the origin URL for DIR, or nil.

DIR is the project root.  Reads `.git/config' only; it does not
contact the remote."
  (let ((default-directory (file-name-as-directory
                            (project-view--canonical-dir DIR)))
        (out nil))
    (with-temp-buffer
      (when (eq 0 (call-process "git" nil t nil
                                "--no-optional-locks"
                                "config" "--get" "remote.origin.url"))
        (setq out (string-trim (buffer-string)))))
    (and out (not (string-empty-p out)) out)))

(defun project-view--placeholder-info ()
  "Return a placeholder Git info plist used before the first refresh."
  (list :branch "…" :status "…" :upstream "…"
        :commit "…" :remote "…" :stash "…"
        :backend 'Git :source 'placeholder))

(defun project-view/git-repo-info (DIR)
  "Return local Git repository information plist for DIR.

DIR is the project directory path.  Runs a single
`git status --porcelain=v2' and does not contact any remote.  Return
nil if Git fails."
  (let* ((default-directory (file-name-as-directory
                             (project-view--canonical-dir DIR)))
         (untracked (if project-view/include-untracked "normal" "no"))
         (status-code nil)
         (output nil))
    (with-temp-buffer
      (setq status-code
            (apply #'call-process "git" nil t nil
                   "--no-optional-locks"
                   "status" "--porcelain=v2" "--branch" "--show-stash"
                   "--ignore-submodules=dirty"
                   (list (concat "--untracked-files=" untracked))))
      (setq output (buffer-string)))
    (when (eq status-code 0)
      (let ((info (project-view--parse-porcelain-v2 output))
            (remote (project-view--git-remote-url DIR))
            (mtimes (project-view--git-mtimes DIR)))
        (setq info (plist-put info :remote (or remote "no remote")))
        (setq info (append info mtimes))
        info))))

(provide 'project-view-git)
;;; project-view-git.el ends here

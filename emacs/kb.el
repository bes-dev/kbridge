;;; kb.el --- Conversational knowledge-base chat (Pi) for Emacs -*- lexical-binding: t; -*-

;; Part of kbridge (https://github.com/bes-dev/kbridge). Browsing, reading,
;; editing and [[wikilinks]] are left to obsidian.el / markdown-mode — this
;; module adds the *agent* layer: a real, streaming, multi-turn chat with your
;; vault, backed by a persistent `pi --mode rpc` process (so it works with a
;; local model for privacy). Everything is async: the single-threaded Emacs UI
;; never blocks while the model thinks, and tokens stream in live.
;;
;; Setup (in your init):
;;   (add-to-list 'load-path "/path/to/kbridge/emacs")
;;   (require 'kb)
;;   ;; for a local/private model, e.g.:
;;   ;; (setq kb-pi-model '("--model" "qwen/qwen3.6-27b"))
;;
;; This library provides commands only; bind them in your config (recommended
;; prefix `C-c k', e.g. via the use-package snippet at the bottom of this file):
;;   C-c k k  kb-chat              open the chat (RET sends, C-j newline, C-c C-k aborts)
;;   C-c k i  kb-ingest-region     file the region into the vault
;;   C-c k b  kb-discuss-buffer    attach the current buffer/region (read-only; C-c C-e edits)
;;   C-c k d  kb-discuss-directory attach the current dir (dired) to the chat
;;   C-c k s  kb-sync              push / pull / status
;; In the chat, [[wikilinks]] in answers are clickable and open the page.

;;; Code:

(require 'subr-x)

(defgroup kb nil "Conversational knowledge base via the Pi coding agent." :group 'tools)

(defcustom kb-pi-program "pi"
  "Path to the Pi executable." :type 'string :group 'kb)

(defcustom kb-pi-rpc-args '("--mode" "rpc" "--no-session")
  "Base arguments for Pi's RPC mode." :type '(repeat string) :group 'kb)

(defcustom kb-pi-model nil
  "Extra Pi args to pin a provider/model (use a local one for privacy).
Example: \\='(\"--model\" \"qwen/qwen3.6-27b\").  Nil uses Pi's default."
  :type '(repeat string) :group 'kb)

(defcustom kb-vault-path-file (expand-file-name "~/.claude/skills/kb/vault_path")
  "File recording the vault root.
Written by kbridge's setup.sh and shared with the Pi and Claude integrations."
  :type 'file :group 'kb)

(defcustom kb-vault-directory nil
  "Vault root directory.  When nil it is read from `kb-vault-path-file'."
  :type '(choice (const :tag "Auto (from kbridge)" nil) directory) :group 'kb)

(defcustom kb-sync-program (expand-file-name "~/.claude/skills/kb/kb-sync")
  "Path to kbridge's kb-sync script." :type 'file :group 'kb)

(defcustom kb-chat-display-action nil
  "ACTION passed to `pop-to-buffer' for the chat buffer.
Nil opens a normal, splittable window.  Set this (or add a
`display-buffer-alist' entry for `*kb-chat*') to place it elsewhere."
  :type 'sexp :group 'kb)

(defconst kb-chat-buffer "*kb-chat*" "Name of the conversational chat buffer.")

(defun kb-vault ()
  "Return the resolved vault root, or signal a clear error."
  (or (and kb-vault-directory (expand-file-name kb-vault-directory))
      (and (file-readable-p kb-vault-path-file)
           (let ((p (string-trim (with-temp-buffer
                                   (insert-file-contents kb-vault-path-file)
                                   (buffer-string)))))
             (and (not (string-empty-p p)) (file-directory-p p) p)))
      (and (boundp 'obsidian-directory) obsidian-directory)
      (user-error "KB vault not configured — run kbridge setup.sh or set `kb-vault-directory'")))

;;;; Clickable [[wikilinks]]

(define-button-type 'kb-wikilink 'follow-link t 'help-echo "Open this vault page"
  'action (lambda (b) (kb-open-page (button-get b 'kb-page))))

(defun kb--buttonize-region (beg end)
  "Turn [[page]] refs between BEG and END into buttons; hide the brackets.
Handles a bare name, a relative path, an alias (NAME|x) and a section (#sec)."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward "\\[\\[\\([^]\n]+?\\)\\]\\]" end t)
      (let* ((m0 (match-beginning 0)) (m1 (match-end 0))
             (inner-beg (+ m0 2)) (inner-end (- m1 2))
             (raw (match-string 1))
             (page (string-trim (car (split-string (car (split-string raw "#")) "|")))))
        (put-text-property m0 inner-beg 'invisible t)
        (put-text-property inner-end m1 'invisible t)
        (make-button inner-beg inner-end :type 'kb-wikilink 'kb-page page)))))

(defun kb--resolve-page (name)
  "Resolve NAME (bare name, basename, or relative path) to a file under the vault."
  (let* ((vault (file-name-as-directory (kb-vault)))
         (name (string-trim name))
         (rel (if (string-suffix-p ".md" name) name (concat name ".md"))))
    (cond
     ((file-exists-p (expand-file-name rel vault)) (expand-file-name rel vault))
     ((file-exists-p (expand-file-name name vault)) (expand-file-name name vault))
     (t (car (ignore-errors
               (directory-files-recursively
                vault (concat "\\`" (regexp-quote (file-name-nondirectory rel)) "\\'"))))))))

(defun kb-open-page (name)
  "Open the vault page referred to by NAME (path, basename, or title)."
  (let ((hit (kb--resolve-page name)))
    (if hit (find-file hit) (message "kb: no page found for %s" name))))

(defun kb--fontify-markdown (beg end)
  "Apply lightweight markdown styling between BEG and END, hiding the markers.
Covers headings, **bold**, `code` and -/*/+ bullets — enough for chat answers."
  (let ((end (copy-marker end)))
    (save-excursion
      (goto-char beg)                       ; headings:  ## Text
      (while (re-search-forward "^\\(#+[ \t]*\\)\\(.+\\)$" end t)
        (put-text-property (match-beginning 1) (match-end 1) 'invisible t)
        (add-face-text-property (match-beginning 2) (match-end 2) 'bold))
      (goto-char beg)                       ; bold:  **text**
      (while (re-search-forward "\\*\\*\\([^*\n]+?\\)\\*\\*" end t)
        (put-text-property (match-beginning 0) (+ 2 (match-beginning 0)) 'invisible t)
        (put-text-property (- (match-end 0) 2) (match-end 0) 'invisible t)
        (add-face-text-property (match-beginning 1) (match-end 1) 'bold))
      (goto-char beg)                       ; inline code:  `text`
      (while (re-search-forward "`\\([^`\n]+\\)`" end t)
        (put-text-property (match-beginning 0) (1+ (match-beginning 0)) 'invisible t)
        (put-text-property (1- (match-end 0)) (match-end 0) 'invisible t)
        (add-face-text-property (match-beginning 1) (match-end 1) 'font-lock-constant-face))
      (goto-char beg)                       ; bullets:  -, *, + → •
      (while (re-search-forward "^\\([ \t]*\\)[-*+]\\([ \t]+\\)" end t)
        (put-text-property (match-beginning 0) (match-end 0)
                           'display (concat (match-string 1) "• "))))))

;;;; Chat buffer state

(defvar-local kb-chat--proc nil "Persistent Pi RPC process for this buffer.")
(defvar-local kb-chat--acc "" "Partial stdout line accumulator.")
(defvar-local kb-chat--busy nil "Non-nil while a turn is streaming.")
(defvar-local kb-chat--input-start nil "Marker where the editable input begins.")
(defvar-local kb-chat--answer-start nil "Marker at the start of the current answer.")
(defvar-local kb-chat--ctxfile nil "Temp file holding the KB system-prompt addendum.")
(defvar-local kb-chat--tool nil "Name of the tool currently running, shown in the header.")
(defvar-local kb-chat--pending nil "Context blocks to prepend to the next submitted message.")
(defvar-local kb-chat--edit-file nil "Absolute path of the file attached for optional editing.")
(defvar-local kb-chat--edit-srcbuf nil "Source buffer of the attached file, for live revert.")
(defvar-local kb-chat--edit-on nil "Non-nil when edit-mode is enabled for the attached file.")
(defvar-local kb-chat--seen-text nil "Non-nil once the current turn has emitted real text.")
(defvar-local kb-chat--spinner-i 0)
(defvar-local kb-chat--spinner-timer nil)
(defvar kb-chat--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])

(defun kb-chat--header ()
  "Header-line for the chat buffer."
  (if kb-chat--busy
      (format " %s  kb: %s    C-c C-k abort"
              (aref kb-chat--spinner-frames (mod kb-chat--spinner-i (length kb-chat--spinner-frames)))
              (if kb-chat--tool (concat "⏳ " kb-chat--tool) "thinking…"))
    (if kb-chat--edit-file
        (format " kb · %s %s · C-c C-e toggle edit · RET send"
                (if kb-chat--edit-on "✎ EDIT" "🔒 read-only")
                (file-name-nondirectory kb-chat--edit-file))
      " kb chat · RET send · C-j newline · [[link]] opens page")))

(defun kb-chat--start-spinner (buffer)
  (with-current-buffer buffer
    (setq kb-chat--spinner-i 0)
    (when (timerp kb-chat--spinner-timer) (cancel-timer kb-chat--spinner-timer))
    (setq kb-chat--spinner-timer
          (run-at-time 0 0.1
                       (lambda (b)
                         (when (buffer-live-p b)
                           (with-current-buffer b
                             (if kb-chat--busy
                                 (progn (setq kb-chat--spinner-i (1+ kb-chat--spinner-i))
                                        (force-mode-line-update))
                               (when (timerp kb-chat--spinner-timer)
                                 (cancel-timer kb-chat--spinner-timer))))))
                       buffer))))

(defun kb-chat--stop-spinner ()
  (when (timerp kb-chat--spinner-timer) (cancel-timer kb-chat--spinner-timer))
  (setq kb-chat--spinner-timer nil)
  (force-mode-line-update))

;;;; RPC process

(defun kb--context-prompt ()
  "Text appended to Pi's system prompt so the chat is vault-aware."
  (let ((v (kb-vault)))
    (format "You are conversing inside my personal knowledge-base vault at `%s`. \
Use the kb_search tool and read files under that path with ABSOLUTE paths (never cd). \
Consult `%s/AGENTS.md` (rules) and `%s/index.md` (project map) as needed and follow them. \
Answer concisely and cite the pages you used as [[wikilinks]]. \
Do NOT modify files unless I explicitly ask." v v v)))

(defun kb-chat--emit (buffer text &optional face)
  "Insert TEXT (optionally with FACE) at the end of BUFFER and follow the tail."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (if face (propertize text 'face face) text))))
      (when-let ((w (get-buffer-window buffer))) (set-window-point w (point-max))))))

(defun kb-chat--handle-event (buffer e)
  "Dispatch one parsed RPC event plist E for BUFFER."
  (let ((type (plist-get e :type)))
    (cond
     ((equal type "message_update")
      (let ((ev (plist-get e :assistantMessageEvent)))
        (when (and ev (equal (plist-get ev :type) "text_delta"))
          (when kb-chat--tool            ; a tool finished — drop it from the header
            (setq kb-chat--tool nil) (force-mode-line-update))
          (let ((delta (or (plist-get ev :delta) "")))
            (if kb-chat--seen-text
                (kb-chat--emit buffer delta)
              ;; Swallow the blank/whitespace deltas the model emits around tool
              ;; calls; left-trim the first chunk of real answer text.
              (let ((trimmed (string-trim-left delta)))
                (unless (string-empty-p trimmed)
                  (setq kb-chat--seen-text t)
                  (kb-chat--emit buffer trimmed))))))))
     ((equal type "tool_execution_start")
      ;; Show tool activity transiently in the header line, not in the transcript.
      (setq kb-chat--tool (or (plist-get e :toolName) "tool"))
      (force-mode-line-update))
     ((equal type "agent_end")
      (kb-chat--finish-turn buffer)))))

(defun kb-chat--filter (buffer _proc string)
  "Process filter: accumulate STRING, parse complete JSON lines for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kb-chat--acc (concat kb-chat--acc string))
      (let ((lines (split-string kb-chat--acc "\n")))
        (setq kb-chat--acc (car (last lines)))
        (dolist (line (butlast lines))
          (unless (string-empty-p (string-trim line))
            (let ((e (ignore-errors
                       (json-parse-string line :object-type 'plist
                                          :null-object nil :false-object nil))))
              (when e (kb-chat--handle-event buffer e)))))))))

(defun kb-chat--sentinel (buffer proc _event)
  (unless (process-live-p proc)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq proc kb-chat--proc)
          (setq kb-chat--busy nil)
          (kb-chat--stop-spinner)
          (kb-chat--emit buffer "\n[kb session ended]\n" 'error))))))

(defun kb-chat--ensure-process (buffer)
  "Start the persistent Pi RPC process for BUFFER if not already running."
  (with-current-buffer buffer
    (unless (and kb-chat--proc (process-live-p kb-chat--proc))
      (setq kb-chat--ctxfile (make-temp-file "kb-ctx" nil ".md" (kb--context-prompt)))
      (let* ((default-directory (file-name-as-directory (kb-vault)))
             (command (append (list kb-pi-program) kb-pi-rpc-args kb-pi-model
                              (list "--append-system-prompt" kb-chat--ctxfile)))
             (proc (make-process
                    :name "kb-rpc" :buffer nil :noquery t :connection-type 'pipe
                    :command command
                    :filter (lambda (p s) (kb-chat--filter buffer p s))
                    :sentinel (lambda (p e) (kb-chat--sentinel buffer p e)))))
        (setq kb-chat--proc proc kb-chat--acc "")))
    kb-chat--proc))

(defun kb-chat--cleanup ()
  "Kill this buffer's RPC process and temp file (on `kill-buffer-hook')."
  (when (and kb-chat--proc (process-live-p kb-chat--proc)) (delete-process kb-chat--proc))
  (when (and kb-chat--ctxfile (file-exists-p kb-chat--ctxfile)) (ignore-errors (delete-file kb-chat--ctxfile))))

(defun kb--kill-all-processes ()
  "Kill every live kb RPC process — belt-and-suspenders for Emacs exit.
A buffer-local `kill-buffer-hook' is not guaranteed to run when Emacs quits,
so this `kill-emacs-hook' makes sure no `pi --mode rpc' process is orphaned."
  (dolist (p (process-list))
    (when (and (process-live-p p) (string-prefix-p "kb-rpc" (process-name p)))
      (ignore-errors (delete-process p)))))

(add-hook 'kill-emacs-hook #'kb--kill-all-processes)

;;;; Turns

(defun kb-chat--submit (msg &optional payload)
  "Render MSG as a user turn; send PAYLOAD (defaults to MSG) to the RPC session.
PAYLOAD lets the agent receive attached context while the transcript shows only MSG."
  (kb-chat--ensure-process (current-buffer))
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize "You: " 'face 'font-lock-keyword-face) msg "\n\n")
    (setq kb-chat--answer-start (point-marker)))
  (setq kb-chat--busy t kb-chat--seen-text nil)
  (kb-chat--start-spinner (current-buffer))
  (force-mode-line-update)
  (process-send-string kb-chat--proc
                       (concat (json-serialize (list :type "prompt" :message (or payload msg))) "\n")))

(defun kb-chat--finish-turn (buffer)
  "End the current turn in BUFFER: buttonize links and show a fresh prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kb-chat--busy nil kb-chat--tool nil)
      (kb-chat--stop-spinner)
      (when (markerp kb-chat--answer-start)
        (let ((inhibit-read-only t))
          (kb--fontify-markdown kb-chat--answer-start (point-max))
          (kb--buttonize-region kb-chat--answer-start (point-max))))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n\n" (propertize "❯ " 'face 'minibuffer-prompt))
        (setq kb-chat--input-start (point-marker)))
      (when-let ((w (get-buffer-window buffer))) (set-window-point w (point-max))))))

(defun kb-chat-send ()
  "Send the text typed after the prompt as the next turn."
  (interactive)
  (unless (derived-mode-p 'kb-chat-mode) (user-error "Not a kb chat buffer"))
  (when kb-chat--busy (user-error "kb is thinking… (C-c C-k to abort)"))
  (let ((msg (string-trim (buffer-substring-no-properties
                           (or kb-chat--input-start (point-min)) (point-max)))))
    (when (string-empty-p msg) (user-error "Type a message first"))
    (let ((payload (if kb-chat--pending
                       (concat (mapconcat #'identity kb-chat--pending "\n\n") "\n\n" msg)
                     msg)))
      (setq kb-chat--pending nil)
      (let ((inhibit-read-only t))
        (delete-region (line-beginning-position) (point-max)))
      (kb-chat--submit msg payload))))

(defun kb-chat-abort ()
  "Abort the current turn (keeps the session alive)."
  (interactive)
  (if (and kb-chat--busy kb-chat--proc (process-live-p kb-chat--proc))
      (progn (process-send-string kb-chat--proc (concat (json-serialize '(:type "abort")) "\n"))
             (message "kb: aborting…"))
    (message "kb: nothing to abort")))

;;;; Mode and entry points

(defvar kb-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'kb-chat-send)
    (define-key m (kbd "C-c C-c") #'kb-chat-send)
    (define-key m (kbd "C-j") #'newline)
    (define-key m (kbd "C-c C-k") #'kb-chat-abort)
    (define-key m (kbd "C-c C-e") #'kb-chat-toggle-edit)
    m)
  "Keymap for `kb-chat-mode'.")

(define-derived-mode kb-chat-mode fundamental-mode "kb-chat"
  "Conversational KB chat backed by a persistent Pi RPC session."
  (setq header-line-format '(:eval (kb-chat--header)))
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'kb-chat--cleanup nil t))

;;;###autoload
(defun kb-chat ()
  "Open (or focus) the conversational KB chat."
  (interactive)
  (let ((buf (get-buffer-create kb-chat-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'kb-chat-mode) (kb-chat-mode))
      (kb-chat--ensure-process buf)
      (when (= (point-max) (point-min))
        (let ((inhibit-read-only t))
          (insert (propertize
                   (format "kb chat · %s\n\n"
                           (file-name-nondirectory (directory-file-name (kb-vault))))
                   'face 'shadow))
          (insert (propertize "❯ " 'face 'minibuffer-prompt))
          (setq kb-chat--input-start (point-marker))))
      (goto-char (point-max)))
    (pop-to-buffer buf kb-chat-display-action)))

;;;###autoload
(defalias 'kb-ask #'kb-chat)

;;;###autoload
(defun kb-ingest-region (beg end)
  "Ask the agent (in the chat) to file the region BEG..END into the vault."
  (interactive "r")
  (let ((text (string-trim (buffer-substring-no-properties beg end))))
    (when (string-empty-p text) (user-error "Empty region"))
    (kb-chat)
    (with-current-buffer kb-chat-buffer
      (when kb-chat--busy (user-error "kb is busy — try again in a moment"))
      (let ((inhibit-read-only t))
        (when (markerp kb-chat--input-start)
          (delete-region (line-beginning-position) (point-max))))
      (kb-chat--submit
       (concat "INGEST the following into the vault per AGENTS.md "
               "(choose location, add YAML front matter, append to log.md, update index.md only if it's a new project, "
               "cross-reference with [[wikilinks]]). Report what you wrote.\n\n---\n" text)))))

;;;###autoload
(defun kb-sync (action)
  "Run kbridge's kb-sync ACTION (push/pull/status) asynchronously."
  (interactive (list (completing-read "kb-sync: " '("status" "pull" "push") nil t nil nil "status")))
  (unless (file-executable-p kb-sync-program)
    (user-error "kb-sync not found at %s (run kbridge setup.sh)" kb-sync-program))
  (let ((buf (get-buffer-create "*kb-sync*")))
    (with-current-buffer buf (let ((inhibit-read-only t)) (erase-buffer)))
    (make-process
     :name "kb-sync" :buffer buf :command (list kb-sync-program action) :noquery t
     :sentinel (lambda (p _e)
                 (unless (process-live-p p)
                   (when (buffer-live-p (process-buffer p))
                     (with-current-buffer (process-buffer p)
                       (message "kb-sync %s: %s" action (string-trim (buffer-string))))))))
    (message "kb-sync %s…" action)))

;;;; Attach context (current buffer / directory) to the chat

(defun kb--lang-hint ()
  "A markdown fence language guessed from the current major mode."
  (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name major-mode)))

(defun kb--dir-listing (dir)
  "A one-level listing of DIR, directories marked with a trailing slash."
  (let ((fs (delete "." (delete ".." (directory-files dir)))))
    (mapconcat (lambda (f)
                 (concat f (if (file-directory-p (expand-file-name f dir)) "/" "")))
               fs "\n")))

(defun kb-chat--attach (label block)
  "Open/focus the chat, stash BLOCK as pending context, note LABEL in the transcript.
The block is prepended to the next message you send, so the agent gets the context
while the transcript shows only your question."
  (kb-chat)
  (with-current-buffer kb-chat-buffer
    (setq kb-chat--pending (append kb-chat--pending (list block)))
    (unless kb-chat--busy
      (let ((inhibit-read-only t))
        (save-excursion
          (when (markerp kb-chat--input-start)
            (goto-char kb-chat--input-start)
            (forward-line 0)
            (insert (propertize (format "📎 %s\n" label) 'face 'shadow))))))
    (message "kb: attached %s — type your question and press RET" label)))

;;;###autoload
(defun kb-discuss-buffer ()
  "Attach the current buffer (or active region) to the kb chat, read-only.
Inside the chat, `C-c C-e' toggles edit-mode for a file-backed buffer so the
agent may edit it in place."
  (interactive)
  (let* ((file (buffer-file-name))
         (name (or file (buffer-name)))
         (srcbuf (current-buffer))
         (region (use-region-p))
         (beg (if region (region-beginning) (point-min)))
         (end (if region (region-end) (point-max)))
         (lang (kb--lang-hint))
         (content (buffer-substring-no-properties beg end))
         (label (format "%s%s%s" (file-name-nondirectory name) (if region " (region)" "")
                        (if file " · read-only, C-c C-e to edit" "")))
         (block (format "Файл для обсуждения (READ-ONLY — не редактируй, пока я не разрешу) — `%s`%s:\n\n```%s\n%s\n```"
                        name (if region " (выделенный фрагмент)" "") lang content)))
    (kb-chat--attach label block)
    (with-current-buffer kb-chat-buffer
      (setq kb-chat--edit-file (and file (expand-file-name file))
            kb-chat--edit-srcbuf (and file srcbuf)
            kb-chat--edit-on nil)
      (force-mode-line-update))))

(defun kb-chat-toggle-edit ()
  "Toggle edit-mode for the file attached to this chat (see `kb-discuss-buffer').
On: save & auto-revert the source buffer and tell the agent it may edit the file
in place.  Off: back to read-only."
  (interactive)
  (unless (derived-mode-p 'kb-chat-mode) (user-error "Not a kb chat buffer"))
  (unless kb-chat--edit-file
    (user-error "No file attached — run `C-c k b' on a file-backed buffer first"))
  (setq kb-chat--edit-on (not kb-chat--edit-on))
  (if kb-chat--edit-on
      (progn
        (when (buffer-live-p kb-chat--edit-srcbuf)
          (with-current-buffer kb-chat--edit-srcbuf
            (when (buffer-modified-p) (save-buffer))
            (auto-revert-mode 1)))
        (setq kb-chat--pending
              (append kb-chat--pending
                      (list (format "Теперь можешь РЕДАКТИРОВАТЬ файл `%s` на месте своими \
edit/write-инструментами (только его; сначала прочитай для точных совпадений)."
                                    kb-chat--edit-file))))
        (let ((inhibit-read-only t))
          (save-excursion
            (when (markerp kb-chat--input-start)
              (goto-char kb-chat--input-start) (forward-line 0)
              (insert (propertize (format "✎ edit-mode ON · %s\n"
                                          (file-name-nondirectory kb-chat--edit-file))
                                  'face 'shadow)))))
        (message "kb: edit-mode ON — %s" (file-name-nondirectory kb-chat--edit-file)))
    (when (buffer-live-p kb-chat--edit-srcbuf)
      (with-current-buffer kb-chat--edit-srcbuf (auto-revert-mode -1)))
    (message "kb: edit-mode OFF (read-only)"))
  (force-mode-line-update))

;;;###autoload
(defun kb-discuss-directory ()
  "Attach the current directory (dired or `default-directory') to the kb chat."
  (interactive)
  (let* ((dir (expand-file-name
               (if (derived-mode-p 'dired-mode) (dired-current-directory) default-directory)))
         (block (format "Рабочая папка для обсуждения — `%s`. \
Работай с файлами под ней по АБСОЛЮТНЫМ путям, CWD не меняй.\n\nСодержимое:\n```\n%s\n```"
                        dir (kb--dir-listing dir))))
    (kb-chat--attach (format "📁 %s" (abbreviate-file-name dir)) block)))

;;;; Keybindings — none installed here. Bind in your config under a free prefix
;; (recommended `C-c k', which avoids obsidian.el's `C-c n' map). With use-package:
;;
;;   (use-package kb
;;     :load-path "/path/to/kbridge/emacs"
;;     :commands (kb-open-page)
;;     :bind (("C-c k k" . kb-chat)
;;            ("C-c k i" . kb-ingest-region)
;;            ("C-c k b" . kb-discuss-buffer)
;;            ("C-c k d" . kb-discuss-directory)
;;            ("C-c k s" . kb-sync)))

(provide 'kb)
;;; kb.el ends here

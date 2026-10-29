;;; nim-ts-mode.el --- A Tree-sitter major mode for Nim -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: MPL-2.0
;; Font-lock query patterns are adapted from alaviss/tree-sitter-nim (MPL-2.0).

;; Author: OpenAI
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, nim, tree-sitter

;;; Commentary:
;;
;; A small, self-contained Nim major mode using Emacs's built-in Tree-sitter
;; support and the grammar at https://github.com/alaviss/tree-sitter-nim.
;;
;; Install the grammar once with:
;;   M-x treesit-install-language-grammar RET nim RET
;;
;; This mode provides Tree-sitter font-locking and a conservative indentation
;; heuristic.  Nim's indentation-sensitive syntax makes perfect indentation
;; inference inherently ambiguous in some editing situations; this is intended
;; as a useful starting point rather than a complete replacement for nim-mode.
;;
;;; Code:

(require 'treesit)
(require 'rx)
(require 'subr-x)

;; Make the grammar source available to `treesit-install-language-grammar'.
(unless (assq 'nim treesit-language-source-alist)
  (add-to-list 'treesit-language-source-alist
               '(nim "https://github.com/alaviss/tree-sitter-nim")))

(defgroup nim-ts-mode nil
  "Tree-sitter support for the Nim programming language."
  :group 'languages
  :prefix "nim-ts-mode-")

(defcustom nim-ts-mode-indent-offset 2
  "Number of spaces used for each indentation step in `nim-ts-mode'."
  :type 'integer
  :safe #'integerp
  :group 'nim-ts-mode)

(defcustom nim-ts-mode-enable-automatic-indentation t
  "Whether RET should use normal Emacs electric indentation in Nim buffers."
  :type 'boolean
  :group 'nim-ts-mode)

(defvar nim-ts-mode--syntax-table
  (let ((table (make-syntax-table)))
    ;; Nim's ordinary comments begin with # and end at newline.  Tree-sitter
    ;; handles nested #[ ... ]# block-comment highlighting independently.
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?_ "w" table)
    table)
  "Syntax table used by `nim-ts-mode'.")

(defvar nim-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'nim
   :feature 'comment
   '([(comment) (block_comment)] @font-lock-comment-face
     [(documentation_comment) (block_documentation_comment)] @font-lock-doc-face)

   :language 'nim
   :feature 'string
   '([(interpreted_string_literal)
      (long_string_literal)
      (raw_string_literal)
      (generalized_string)] @font-lock-string-face
     (char_literal) @font-lock-string-face
     (escape_sequence) @font-lock-escape-face)

   :language 'nim
   :feature 'number
   '([(integer_literal) (custom_numeric_literal)] @font-lock-number-face
     (float_literal) @font-lock-number-face
     (nil_literal) @font-lock-constant-face)

   :language 'nim
   :feature 'constant
   '((nil_literal) @font-lock-constant-face
     ((identifier) @font-lock-constant-face
      (:match "\\`\\(?:true\\|false\\)\\'" @font-lock-constant-face)))

   :language 'nim
   :feature 'definition
   '((proc_declaration name: (_) @font-lock-function-name-face)
     (func_declaration name: (_) @font-lock-function-name-face)
     (method_declaration name: (_) @font-lock-function-name-face)
     (iterator_declaration name: (_) @font-lock-function-name-face)
     (converter_declaration name: (_) @font-lock-function-name-face)
     (macro_declaration name: (_) @font-lock-function-name-face)
     (template_declaration name: (_) @font-lock-function-name-face)
     (type_symbol_declaration name: (_) @font-lock-type-face)
     (symbol_declaration name: (_) @font-lock-variable-name-face))

   :language 'nim
   :feature 'function
   '((call
      function: [(identifier) @font-lock-function-call-face
                 (dot_expression right: (identifier) @font-lock-function-call-face)])
     (generalized_string
      function: [(identifier) @font-lock-function-call-face
                 (dot_expression right: (identifier) @font-lock-function-call-face)]))

   :language 'nim
   :feature 'type
   '((type_expression (identifier) @font-lock-type-face)
     (parameter_declaration
      (symbol_declaration_list
       (symbol_declaration name: (_) @font-lock-variable-name-face))))

   :language 'nim
   :feature 'keyword
   '(["if" "when" "case" "elif" "else" "for" "while"
      "continue" "break" "import" "include" "export" "from"
      "macro" "template" "const" "let" "var" "asm" "bind"
      "block" "concept" "defer" "discard" "distinct" "do"
      "enum" "mixin" "nil" "object" "out" "ptr" "ref"
      "static" "tuple" "type" "proc" "func" "method"
      "converter" "iterator" "and" "or" "xor" "not" "div"
      "mod" "shl" "shr" "as" "of" "in" "notin" "is"
      "isnot" "cast" "return" "yield" "try" "except"
      "finally" "raise" "using"] @font-lock-keyword-face)

   :language 'nim
   :feature 'operator
   '((infix_expression operator: _ @font-lock-operator-face)
     (prefix_expression operator: _ @font-lock-operator-face)
     ["=" "+" "-" "*" "/" "<" ">" "@" "$" "~" "&" "%"
      "|" "!" "?" "^" "." ":" "\\" "∙" "∘" "×" "★"
      "⊗" "⊘" "⊙" "⊛" "⊠" "⊡" "∩" "∧" "⊓" "±" "⊕"
      "⊖" "⊞" "⊟" "∪" "∨" "⊔"] @font-lock-operator-face)

   :language 'nim
   :feature 'delimiter
   '(["." "," ";" ":"] @font-lock-delimiter-face)

   :language 'nim
   :feature 'bracket
   '(["(" ")" "[" "]" "{" "}" "{." ".}"] @font-lock-bracket-face)

   :language 'nim
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock rules for `nim-ts-mode'.")

(defvar nim-ts-mode--font-lock-feature-list
  '((comment)
    (keyword type)
    (definition function)
    (string number constant)
    (operator delimiter bracket error))
  "Tree-sitter font-lock feature levels for `nim-ts-mode'.")

(defun nim-ts-mode--line-text (&optional position)
  "Return trimmed text of the line at POSITION (or the current line)."
  (save-excursion
    (when position (goto-char position))
    (beginning-of-line)
    (let ((begin (point))
          (end (line-end-position)))
      (string-trim (buffer-substring-no-properties begin end)))))

(defun nim-ts-mode--line-indent (&optional position)
  "Return indentation of the line at POSITION (or current line)."
  (save-excursion
    (when position (goto-char position))
    (current-indentation)))

(defun nim-ts-mode--previous-code-line ()
  "Return (INDENT . TEXT) for the preceding nonblank, non-line-comment line.
Return nil if there is no such line."
  (save-excursion
    (beginning-of-line)
    (let (result)
      (while (and (not result) (= (forward-line -1) 0))
        (let ((text (nim-ts-mode--line-text))
              (indent (current-indentation)))
          (unless (or (string-empty-p text)
                      (string-match-p "\\`#" text))
            (setq result (cons indent text)))))
      result)))

(defun nim-ts-mode--branch-keyword (text)
  "Return the branch keyword at the start of TEXT, if any."
  (when (string-match
         "\\`\\(elif\\|else\\|of\\|except\\|finally\\)\\_>" text)
    (match-string 1 text)))

(defun nim-ts-mode--branch-indent (branch body-indent)
  "Find the indentation of the control header for BRANCH.
BODY-INDENT is the indentation of the previous code line."
  (let ((wanted (pcase branch
                  ((or "elif" "else") "\\(?:if\\|when\\|case\\)")
                  ("of" "case")
                  ((or "except" "finally") "try")
                  (_ nil)))
        found)
    (when wanted
      (save-excursion
        (beginning-of-line)
        (while (and (not found) (= (forward-line -1) 0))
          (let ((text (nim-ts-mode--line-text))
                (indent (current-indentation)))
            (when (and (< indent body-indent)
                       (not (string-empty-p text))
                       (not (string-match-p "\\`#" text))
                       (string-match-p
                        (concat "\\`" wanted "\\_>") text))
              (setq found indent)))))
    found)))

(defun nim-ts-mode--block-opener-p (text)
  "Return non-nil if TEXT plausibly opens a layout block."
  (or
   ;; Most Nim control-flow constructs and command-style blocks end in a colon.
   (string-match-p ":[ \t]*\\(?:#.*\\)?\\'" text)
   ;; Section declarations introduce an indented list of declarations.
   (member (downcase text) '("type" "const" "let" "var" "using"))
   ;; Routine bodies normally follow '='.  Also accept other incomplete
   ;; trailing '=' lines as useful continuation indentation.
   (string-match-p "=[ \t]*\\(?:#.*\\)?\\'" text)
   ;; Object/enum/tuple type bodies have fields or variants below them.
   (string-match-p "=[ \t]*\\(?:object\\|enum\\|tuple\\)\\_>.*\\'" text)))

(defun nim-ts-mode--open-delimiter-indent ()
  "Return continuation indentation when the current line is inside delimiters.
Otherwise return nil."
  (let* ((state (syntax-ppss (line-beginning-position)))
         (depth (car state))
         (open (nth 1 state)))
    (when (and (numberp depth) (> depth 0) (integer-or-marker-p open))
      (save-excursion
        (goto-char open)
        (let ((open-column (current-column))
              (after-open (1+ open)))
          (goto-char after-open)
          (skip-chars-forward " \t")
          (if (and (< (point) (line-end-position))
                   (not (eq (char-after) ?\n)))
              (current-column)
            (+ open-column nim-ts-mode-indent-offset)))))))

(defun nim-ts-mode--closing-delimiter-indent ()
  "Return matching opener indentation for a line starting with a closer."
  (save-excursion
    (back-to-indentation)
    (when (looking-at-p "[])}]")
      (let* ((state (syntax-ppss (point)))
             (open (nth 1 state)))
        (when (and (> (car state) 0) (integer-or-marker-p open))
          (goto-char open)
          (current-column))))))

(defun nim-ts-mode-calculate-indentation ()
  "Calculate a conservative indentation level for the current Nim line.
This uses Tree-sitter-compatible editing plus layout-aware heuristics."
  (save-excursion
    (back-to-indentation)
    (let* ((current-text (buffer-substring-no-properties (point) (line-end-position)))
           (previous (nim-ts-mode--previous-code-line))
           (previous-indent (or (car-safe previous) 0))
           (previous-text (cdr-safe previous))
           (branch (nim-ts-mode--branch-keyword current-text))
           (branch-indent (and branch
                               (nim-ts-mode--branch-indent branch previous-indent)))
           (closer-indent (nim-ts-mode--closing-delimiter-indent))
           (delimiter-indent (nim-ts-mode--open-delimiter-indent)))
      (cond
       (closer-indent closer-indent)
       (branch-indent branch-indent)
       (delimiter-indent delimiter-indent)
       ((null previous) 0)
       ((nim-ts-mode--block-opener-p previous-text)
        (+ previous-indent nim-ts-mode-indent-offset))
       ;; A line ending in a comma or a binary operator is commonly continued
       ;; on the next line.  Keep the rule conservative to avoid over-indenting
       ;; ordinary complete statements.
       ((string-match-p "[,+*/&|]\\s-*\\(?:#.*\\)?\\'" previous-text)
        (+ previous-indent nim-ts-mode-indent-offset))
       (t previous-indent)))))

(defun nim-ts-mode-indent-line ()
  "Indent the current Nim line using `nim-ts-mode-calculate-indentation'."
  (interactive)
  (let ((target (max 0 (nim-ts-mode-calculate-indentation)))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to target)
    (when (> offset 0)
      (move-to-column (+ target offset)))))

;;;###autoload
(define-derived-mode nim-ts-mode prog-mode "Nim[TS]"
  "Major mode for Nim using Emacs's built-in Tree-sitter support.

Install the Nim grammar with `M-x treesit-install-language-grammar RET nim RET'."
  :group 'nim-ts-mode
  (unless (treesit-language-available-p 'nim)
    (user-error
     "Nim Tree-sitter grammar is not installed; run M-x treesit-install-language-grammar RET nim RET"))

  (set-syntax-table nim-ts-mode--syntax-table)
  (treesit-parser-create 'nim)

  (setq-local treesit-font-lock-settings nim-ts-mode--font-lock-settings)
  (setq-local treesit-font-lock-feature-list
              nim-ts-mode--font-lock-feature-list)
  (treesit-major-mode-setup)

  ;; Use spaces: Nim's layout syntax is indentation-sensitive.
  (setq-local indent-tabs-mode nil)
  (setq-local indent-line-function #'nim-ts-mode-indent-line)
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local comment-use-syntax t)
  (setq-local paragraph-start "[ \t]*$")
  (unless nim-ts-mode-enable-automatic-indentation
    (setq-local electric-indent-inhibit t)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nim\\'" . nim-ts-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nims\\'" . nim-ts-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nimble\\'" . nim-ts-mode))

(provide 'nim-ts-mode)
;;; nim-ts-mode.el ends here

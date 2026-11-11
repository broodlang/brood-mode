;;; brood.el --- Brood (Lisp) editing mode and REPL    -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Wilhelm Kirschbaum

;; Author: Wilhelm Kirschbaum
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/broodlang/brood-mode
;; Keywords: languages, lisp, processes

;; This file is part of brood-mode.

;; brood-mode is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; brood-mode is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with brood-mode.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Major mode for editing Brood, a small dynamically-typed Lisp-1
;; implemented in Rust (the `brood' project).  It derives from
;; `lisp-data-mode', so it inherits Emacs' full s-expression machinery
;; (navigation, electric pairs, `forward-sexp', structural editing), and
;; adds Brood-specific syntax, font-lock and indentation.
;;
;; It also bundles the process integration (one file, no autoload dance):
;;   - `run-brood'      — an inferior Brood REPL over comint (run through a
;;                        pipe so the CLI takes its clean, non-`rustyline' path).
;;   - `brood-send-*'   — evaluate the last sexp / definition / region / buffer
;;                        in that REPL, the way `eval-last-sexp' works for elisp.
;;   - `brood-run'      — run the current file with `brood' in a
;;                        `brood-compilation-mode' buffer, where Brood's GNU
;;                        `FILE:LINE:COL: message' diagnostics are clickable
;;                        (see docs/tooling.md).
;;   - `brood-test' / `brood-new' / `brood-doc' — drive the `nest' project tool
;;                        (the project half of the brood/nest split, ADR-028:
;;                        `brood' runs the language, `nest' runs the project) to
;;                        run the suite, scaffold a project, or emit Markdown docs.
;;   - `brood-toggle-test' — jump between a source file and its test
;;                        (`src/foo.blsp' <-> `tests/foo_test.blsp').
;;   - `brood-format-buffer' — reformat the buffer with the canonical
;;                        `std/format.blsp' formatter (the same code `nest
;;                        format' runs), for output identical to it.  Indentation
;;                        (TAB) approximates that layout; this command is exact.
;;                        Set `brood-format-on-save' to reformat on save.
;;
;; For richer editing the mode registers the `brood-lsp' language server with
;; Eglot (`M-x brood-eglot', or plain `M-x eglot'); see docs/lsp.md.  The server
;; is live and provides: diagnostics — both syntactic (read off a lossless CST,
;; so they work mid-edit) and advisory semantic ones (unbound names, arity and
;; type misuse, from the type checker, as warnings); completion (locals, special
;; forms, and globals, with signatures/docs filled in on demand); hover
;; documentation; signature help; a `documentSymbol' outline; find-references and
;; document-highlight; rename; semantic-token highlighting; and go-to-definition
;; (`M-.').  It bootstraps the enclosing project once, so cross-module names and
;; the test-framework macros resolve, and `M-.' jumps to a definition in another
;; module of the project, into the standard library (a cached copy of the
;; prelude), or — on the name in `(require 'foo)' — to that module's file.
;; `brood-mode' enables Eglot automatically
;; (`eglot-ensure' on the mode hook); one server is shared across buffers, and
;; if the `brood-lsp' binary isn't built / on PATH yet it just warns once
;; (point `brood-eglot-server-program' at a build during development).
;;
;; Brood surface notes that shape this mode:
;;   - Lisp-1, lexical scope, proper tail calls; Clojure-flavoured.
;;   - `def' / `defn' / `defmacro' define; `fn'/`lambda' are closures.  The
;;     module system is `defmodule' / `require' / `provide'; dynamic
;;     (process-scoped) variables are `defdyn' / `binding'.
;;   - `[...]' vectors and `{...}' maps are both immutable data types.
;;   - quasiquote is ` , unquote is ~ , splice is ~@  (Clojure's spelling).
;;   - `:keyword's self-evaluate; only nil/false are falsy.
;;   - `&optional' / `&' for variable arity (CL/Elisp spelling).
;;   - immutable: no `set!', no `while'; loops are recursion or processes.
;;
;; Registered for the `.blsp' extension (the canonical Brood source
;; extension).  Older Brood code may still use `.lisp'; to apply this mode
;; there, add a file- or dir-local setting, e.g. `-*- mode: brood -*-'.
;;
;; The `brood' binary is not usually on PATH while the language is under
;; development.  Either install it, or customize `brood-program-name' to a
;; build, e.g. "~/src/whk/mylisp/target/debug/brood", or the repo's "bin/cli".

;;; Code:

(require 'lisp-mode)
(require 'comint)
(require 'compile)
(require 'ansi-color)

(defgroup brood nil
  "Editing and running Brood code."
  :link '(custom-group-link :tag "Font Lock Faces group" font-lock-faces)
  :group 'lisp)

(defcustom brood-mode-hook nil
  "Normal hook run when entering `brood-mode'.
See `run-hooks'."
  :type 'hook
  :group 'brood)

;;; Syntax table

(defvar brood-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Symbol constituents beyond word chars.  Brood symbols may contain
    ;; arithmetic/comparison glyphs and the predicate `?'/`!' suffixes,
    ;; and `:' (keywords are symbols beginning with `:').
    (dolist (ch '(?+ ?- ?* ?/ ?< ?> ?= ?! ?? ?% ?_ ?& ?^ ?. ?:))
      (modify-syntax-entry ch "_" st))

    ;; Whitespace.
    (modify-syntax-entry ?\t "    " st)
    (modify-syntax-entry ?\f "    " st)
    (modify-syntax-entry ?\r "    " st)
    (modify-syntax-entry ?\s "    " st)

    ;; Lists and the bracket/brace delimiters.  `[]' are vectors and
    ;; `{}' are maps (both literal data types); all balance for editing.
    (modify-syntax-entry ?\( "()  " st)
    (modify-syntax-entry ?\) ")(  " st)
    (modify-syntax-entry ?\[ "(]  " st)
    (modify-syntax-entry ?\] ")[  " st)
    (modify-syntax-entry ?{  "(}  " st)
    (modify-syntax-entry ?}  "){  " st)

    ;; Comments: `;' to end of line.
    (modify-syntax-entry ?\; "<   " st)
    (modify-syntax-entry ?\n ">   " st)

    ;; Strings.
    (modify-syntax-entry ?\" "\"   " st)
    (modify-syntax-entry ?\\ "\\   " st)

    ;; Expression prefixes: quote ', quasiquote `, unquote ~, splice @.
    (modify-syntax-entry ?\' "'   " st)
    (modify-syntax-entry ?\` "'   " st)
    (modify-syntax-entry ?~  "'   " st)
    (modify-syntax-entry ?@  "'   " st)
    st)
  "Syntax table for `brood-mode'.")

(defvar brood-mode-abbrev-table nil)
(define-abbrev-table 'brood-mode-abbrev-table ())

;;; Imenu

(defvar brood-imenu-generic-expression
  `(("Functions"
     ,(rx bol (* space) "(def" (or "n" "macro") (+ space)
          (group (+ (or word (syntax symbol)))))
     1)
    ("Modules"
     ,(rx bol (* space) "(defmodule" (+ space)
          (group (+ (or word (syntax symbol)))))
     1)
    ("Dynamic vars"
     ,(rx bol (* space) "(defdyn" (+ space)
          (group (+ (or word (syntax symbol)))))
     1)
    (nil
     ,(rx bol (* space) "(def" (+ space)
          (group (+ (or word (syntax symbol)))))
     1))
  "Imenu generic expression for `brood-mode'.
See `imenu-generic-expression'.")

;;; Font lock

(defconst brood-special-forms
  '("if" "do" "fn" "let" "letrec" "quote" "quasiquote" "impl"
    "when" "cond" "and" "or" "match" "case" "comment"
    "try" "catch" "throw" "receive" "binding" "doseq"
    "for" "->" "spawn" "spawn-link" "error" "with-out-str" "with-err-str")
  "Brood special forms and core macros to highlight as control keywords.
The canonical set the kernel reports via `(special-forms)' — shared with the
LSP and the REPL highlighter (ADR-092).  GENERATED: regenerate with `nest
grammar emacs' in the brood repo; do not hand-edit.  A new special form belongs
in the kernel's `SPECIAL_FORMS', then regenerate, so every editor stays in sync.
The `def…' heads are highlighted by the definition rule, not this list.  Brood
has no `set!', `while', or `loop'.")

(defconst brood-doc-forms
  '(("defmacro" . fn) ("defability" . head) ("defmodule" . head)
    ("defserver" . fn) ("defn" . fn) ("defn-" . fn))
  "Brood `def…' heads whose form carries a docstring, as (HEAD . KIND).
KIND is `fn' when the head builds a function — there a lone trailing string is
the return value, not documentation — or `head' when the docstring may be the
form's last element.  GENERATED: regenerate with `nest grammar emacs' in the
brood repo; do not hand-edit.  The canonical list is the kernel's `(doc-forms)',
shared with the LSP's semantic tokens and the VS Code / tree-sitter grammars, so
a docstring reads the same in every editor.")

(defun brood--doc-string-p (list-beginning string-start)
  "Non-nil if the string at STRING-START documents the form at LIST-BEGINNING.
A docstring and a string value are the same TOKEN — only position separates them
(`brood-doc-forms'): the string right after the name, or after the parameter
list, of a doc-carrying `def…' form.  With one asymmetry, which is exactly the
confusing case: a function whose body is a LONE string RETURNS that string, so
`(defn greeting () \"hello\")' is a value and only the first string of
`(defn greeting () \"Doc.\" \"hello\")' is documentation.  A `defmodule' has no
body to follow its docstring, so there the last form may well be the doc."
  (when list-beginning
    (save-excursion
      (goto-char list-beginning)
      (when (looking-at "([ \t\n]*\\(\\(?:\\sw\\|\\s_\\)+\\)")
        (let ((kind (cdr (assoc (match-string-no-properties 1) brood-doc-forms))))
          (when kind
            (let ((count 0) (parameters nil) (reached nil))
              (goto-char (1+ list-beginning))
              (condition-case nil
                  (progn
                    (forward-comment (point-max))
                    (while (< (point) string-start)
                      (when (and (= count 2) (memq (char-after) '(?\( ?\[)))
                        (setq parameters t))
                      (forward-sexp 1)
                      (setq count (1+ count))
                      (forward-comment (point-max)))
                    (setq reached (= (point) string-start)))
                (error nil))
              (and reached
                   ;; third form, or fourth when a parameter list comes between
                   (or (= count 2) (and (= count 3) parameters))
                   (or (eq kind 'head)
                       (brood--form-follows-p string-start))))))))))

(defun brood--form-follows-p (string-start)
  "Non-nil if another form follows the string at STRING-START in its list."
  (save-excursion
    (goto-char string-start)
    (condition-case nil
        (progn (forward-sexp 1)
               (forward-comment (point-max))
               (not (memq (char-after) '(?\) ?\] ?} nil))))
      (error nil))))

(defun brood-font-lock-syntactic-face-function (state)
  "Return the face for the string or comment STATE is inside.
Like `lisp-font-lock-syntactic-face-function', but with Brood's docstring
positions (`brood--doc-string-p') in place of Emacs Lisp's `doc-string-elt'
properties — which Brood's `defn'/`defmodule' do not carry, so every docstring
used to fontify as an ordinary string value."
  (if (nth 3 state)
      (let ((string-start (nth 8 state)))
        (if (brood--doc-string-p (nth 1 state) string-start)
            'font-lock-doc-face
          'font-lock-string-face))
    'font-lock-comment-face))

(defvar brood-font-lock-keywords
  (list
   ;; Definitions: any `def…' head — (def NAME …), (defn NAME …),
   ;; (defmacro NAME …), (defdyn NAME …), (defmodule NAME …), (deftest NAME …).
   (list (concat "(\\(def\\(?:\\sw\\|\\s_\\)*\\)\\_>"
                 "[ \t]*"
                 "\\(\\(?:\\sw\\|\\s_\\)+\\)?")
         '(1 font-lock-keyword-face)
         '(2 font-lock-function-name-face nil t))
   ;; Special forms / core macros.
   (cons (concat "(" (regexp-opt brood-special-forms t) "\\_>") 1)
   ;; Self-evaluating constants.
   '("\\_<\\(?:nil\\|true\\|false\\)\\_>" . font-lock-constant-face)
   ;; Keywords:  :foo
   '("\\_<:\\(?:\\sw\\|\\s_\\)+\\_>" . font-lock-builtin-face)
   ;; Parameter-list markers:  &optional  &
   '("\\_<&\\(?:optional\\)?\\_>" . font-lock-type-face))
  "Expressions to highlight in `brood-mode'.")

;;; Indentation
;;
;; The canonical formatter (`nest format', `std/format.blsp') is the source of
;; truth, and its layout is simpler than Common Lisp's: a broken form puts its
;; body lines `lisp-body-indent' (2) columns from the opening bracket — never
;; aligned under the first argument the way `lisp-indent-function' does by
;; default, and never at 2x for a "distinguished" argument.  Only two shapes
;; depart from that +2, and both are pair shapes:
;;
;;   - PAIR-ALIGNED (+1): a map literal `{k v, k v}' and the bindings list of
;;     `let' and friends.  Their elements are name/value pairs, one pair per
;;     line, aligned under the opening element.
;;   - PAIR-BODY VALUE (+4): in `cond'/`case'/`assoc'/`assoc!'/`project', a
;;     clause's value drops to its own line when the pair doesn't fit, indented
;;     +2 from the clause (the formatter's "miser drop").
;;
;; So there is no per-form header table here: how many arguments ride the head
;; line changes what the *formatter* emits, not what column a continuation line
;; lands in, which is all indentation has to answer.

(defvar calculate-lisp-indent-last-sexp)

(defconst brood-pair-binding-forms
  '("let" "letrec" "binding" "loop")
  "Forms whose first argument is a bindings list of name/value pairs.
Mirrors `*format-pair-bindings*' in `std/format.blsp'.  Such a list aligns its
pairs one column past its open paren, under the first name.")

(defconst brood-pair-body-forms
  '(("cond" . 0) ("case" . 1) ("assoc" . 1) ("assoc!" . 1) ("project" . 0))
  "Forms whose body arguments are emitted as pairs, and their header count.
Mirrors `*format-pair-body*' and `*format-headers*' in `std/format.blsp'.  The
header count is how many arguments precede the pairs (`cond' has none; `case'
takes the scrutinee first).  A pair's value, when it drops to its own line,
indents +2 from the clause — see `brood--pair-body-value-p'.")

(defun brood--head-symbol (open)
  "The head symbol's name of the list opening at OPEN, or nil.
Nil when the bracket is not a `(', or its first element is not a symbol."
  (and (eq (char-after open) ?\()
       (save-excursion
         (goto-char (1+ open))
         (forward-comment (point-max))
         (and (looking-at "\\(?:\\sw\\|\\s_\\)+")
              (match-string-no-properties 0)))))

(defun brood--nth-arg-start (open n)
  "Buffer position where argument N of the list at OPEN starts, or nil.
Argument 0 is the one after the head."
  (save-excursion
    (goto-char (1+ open))
    (condition-case nil
        ;; Past the head and N+1 arguments, then back to the last one's start.
        (progn (forward-sexp (+ n 2))
               (forward-sexp -1)
               (point))
      (error nil))))

(defun brood--parent-open (open opens)
  "The position of the bracket enclosing OPEN, or nil.
OPENS is the innermost-first list of open positions (`(elt state 9)' reversed)."
  (cadr (memql open opens)))

(defun brood--pair-aligned-p (open opens)
  "Non-nil if the bracket at OPEN aligns its contents under its first element.
That is a map literal, or the bindings list of a `brood-pair-binding-forms'
head — the two pair shapes the formatter renders one pair per line.  OPENS is
the innermost-first list of open positions."
  (cond
   ;; `{…}' is a map; `#{…}' is a set, which breaks like a vector (+2).
   ((eq (char-after open) ?\{) (not (eq (char-before open) ?#)))
   ((eq (char-after open) ?\()
    ;; A bindings list has no head of its own — it is recognised by its parent:
    ;; `(let (a 1 b 2) …)', where it is the FIRST argument of a let-family head.
    (let ((parent (brood--parent-open open opens)))
      (and parent
           (member (brood--head-symbol parent) brood-pair-binding-forms)
           (eql (brood--nth-arg-start parent 0) open)
           ;; …and PARENT is a FORM, not a bindings list that merely begins with
           ;; the same symbol: in `(letrec (loop (fn (i acc) …)))' the binder is
           ;; named `loop', so the bindings list reads as a `loop' form and the
           ;; `(fn …)' bound to it would read as ITS bindings list.
           (not (brood--pair-aligned-p parent opens)))))))

(defun brood--pair-walk-value-p (from target)
  "Non-nil if the form at or after TARGET fills a pair's VALUE slot.
Walks the forms from FROM the way the formatter pairs them — name + value, one
pair per line — rather than counting to parity, because a COMMENT breaks a pair:
the formatter emits the form before it alone and starts a fresh pair after it,
so one comment flips every following form between the two slots."
  (save-excursion
    (goto-char from)
    (condition-case nil
        (let ((value nil) (done nil))
          (while (not done)
            (forward-comment (point-max))     ; a comment restarts the pairing
            (cond
             ((>= (point) target) (setq done t))          ; a name starts here
             (t
              (forward-sexp 1)                ; consume the name
              (skip-chars-forward " \t\n\r,")
              (cond
               ((eobp) (setq done t))
               ((eq (char-after) ?\;) nil)    ; comment: the name stood alone
               ((>= (point) target) (setq value t done t))
               (t (forward-sexp 1))))))       ; consume the value, next pair
          value)
      (error nil))))

(defun brood--pair-body-value-p (indent-point open)
  "Non-nil if the line at INDENT-POINT starts the VALUE half of a clause pair.
The list at OPEN must have a `brood-pair-body-forms' head, whose body arguments
are emitted two per line (`cond' test + result, `case' pattern + body); a value
that will not fit beside its test drops to the next line, indented +2 from it."
  (let ((entry (assoc (brood--head-symbol open) brood-pair-body-forms)))
    (when entry
      (let ((first-clause
             (save-excursion
               (goto-char (1+ open))
               (condition-case nil
                   ;; Past the head and this form's header arguments (`cond' has
                   ;; none, `case' takes the scrutinee) to the first clause.
                   (progn (forward-sexp (1+ (cdr entry))) (point))
                 (error nil)))))
        (and first-clause
             (brood--pair-walk-value-p first-clause indent-point))))))

(defun brood--keyword-unit-shift (open opens)
  "How many columns the formatter's `:keyword value' unit shifts OPEN's line.
A keyword argument and the form after it are rendered as ONE body item, at the
body indent — so everything on that line after the keyword sits further right
than the layout it was measured against:

    (describe \"…\"
      :isolated (test \"…\"
        (let (a 1
              b 2)
          …)))

The `test' body and the bindings list are both laid out as if `test' began at
`:isolated' (column six), not where it actually starts (column sixteen).  The
difference — here ten columns — is that shift, and every bracket on the line is
measured from its own column minus it.  Zero unless the line begins with a
keyword argument whose enclosing form is a body: inside a map or a bindings list
a `:key value' pair is rendered at its true column, and so is a `cond' clause.
OPENS is the innermost-first list of open positions."
  (save-excursion
    (goto-char open)
    (let ((bol (line-beginning-position)))
      (goto-char bol)
      (skip-chars-forward " \t")
      (let ((container (seq-find (lambda (o) (< o bol)) opens))
            (keyword-column (current-column)))
        (if (and (eq (char-after) ?:)
                 (< (point) open)
                 container
                 (eq (char-after container) ?\()
                 (not (brood--pair-aligned-p container opens))
                 (not (assoc (brood--head-symbol container) brood-pair-body-forms))
                 (condition-case nil (progn (forward-sexp 1) t) (error nil))
                 (progn (skip-chars-forward " \t")
                        (and (<= (point) open) (not (eolp)))))
            (- (current-column) keyword-column)
          0)))))

(defun brood--logical-open-column (open opens)
  "The column the formatter lays out the body of the bracket at OPEN from.
OPENS is the innermost-first list of enclosing open positions.  The answer is
OPEN's own column, less any `brood--keyword-unit-shift' its line carries."
  (- (save-excursion (goto-char open) (current-column))
     (brood--keyword-unit-shift open opens)))

(defun brood-indent-function (indent-point state)
  "Brood mode function for the variable `lisp-indent-function'.
Reproduces the columns `nest format' (`std/format.blsp') emits, so
\\[indent-for-tab-command] leaves already-formatted code untouched: a body line
indents `lisp-body-indent' columns from its opening bracket, a pair-aligned
bracket's contents one column past it, and a dropped pair value +2 from its
clause.  It does not perform the formatter's line-filling or pair-joining — use
\\[brood-format-buffer] for output byte-identical to `nest format'.

INDENT-POINT and STATE are as for the variable `lisp-indent-function'."
  (let* ((open (elt state 1))
         (opens (reverse (elt state 9)))
         (open-column (brood--logical-open-column open opens)))
    (cond
     ((brood--pair-aligned-p open opens) (1+ open-column))
     ((brood--pair-body-value-p indent-point open)
      (+ open-column (* 2 lisp-body-indent)))
     (t (+ open-column lisp-body-indent)))))

(defun brood--calculate-indent (&optional pos)
  "The column the line at POS should be indented to, or nil to leave it alone.
Nil means the line starts inside a string.  Unlike `calculate-lisp-indent' this
always asks `brood-indent-function': the Emacs original has branches that answer
without calling the hook at all — notably \"the line follows the open bracket
directly\", which aligns one column in — and those answers are Common Lisp's,
not `nest format's."
  (save-excursion
    (when pos (goto-char pos))
    (beginning-of-line)
    (let ((state (syntax-ppss (point))))
      (cond
       ;; Inside a string (a multi-line docstring): its columns are content.
       ((nth 3 state) nil)
       ;; A top-level form starts at column 0.
       ((null (nth 1 state)) 0)
       ;; A line that begins with the closing bracket sits at the column the
       ;; matching OPEN was laid out from — the formatter drops a delimiter to
       ;; its own line only when the body ends in a comment, and puts it there.
       ((save-excursion (skip-chars-forward " \t") (looking-at "[])}]"))
        (let* ((open (nth 1 state))
               (opens (reverse (nth 9 state)))
               (column (brood--logical-open-column open opens)))
          (if (brood--pair-aligned-p open opens) (1+ column) column)))
       (t (brood-indent-function (point) state))))))

(defun brood-indent-line (&optional indent)
  "Indent the current line as Brood code, INDENT overriding the computation.
Like `lisp-indent-line', except for two Emacs Lisp conventions Brood does not
share.  A COMMENT is indented as code: Emacs reserves `comment-column' for a `;'
comment and column 0 for a `;;;' one, while `nest format' puts every comment at
the indentation of the code around it, whatever its semicolon count — following
the Emacs convention here made \\[indent-region] shove every `;' comment in a
formatted file out to column 40.  And the column comes from
`brood--calculate-indent' rather than `calculate-lisp-indent'."
  (interactive)
  (let ((pos (- (point-max) (point)))
        (indent (or indent (brood--calculate-indent)))
        (beg (progn (beginning-of-line) (point)))
        shift-amt)
    (skip-chars-forward " \t")
    (if (null indent)
        ;; The line starts inside a string — leave it exactly as it is.
        (goto-char (- (point-max) pos))
      (when (listp indent) (setq indent (car indent)))
      (setq shift-amt (- indent (current-column)))
      (unless (zerop shift-amt)
        (delete-region beg (point))
        (indent-to indent))
      ;; If point was inside the line's indentation it now sits after it; else
      ;; restore it (`lisp-indent-line's contract).
      (when (> (- (point-max) pos) (point))
        (goto-char (- (point-max) pos))))))

;;; Running Brood — shared configuration

(defcustom brood-program-name "brood"
  "Program invoked by \\[run-brood] and \\[brood-run].
The Brood language CLI (it runs the language: the REPL, a file, a single
test file).  Project commands go through `nest-program-name' instead — the
brood/nest split, ADR-028.  If `brood' is not on your PATH (common during
language development), set this to a build such as
\"~/src/whk/mylisp/target/debug/brood\" or to the repo's \"bin/cli\"."
  :type 'string
  :group 'brood)

(defcustom nest-program-name "nest"
  "Project tool invoked by \\[brood-test], \\[brood-new] and \\[brood-doc].
The Brood `nest' binary — the project half of the brood/nest split (ADR-028:
`brood' runs the language, `nest' runs the project: test discovery,
scaffolding, docs).  If `nest' is not on your PATH (common during language
development), set this to a build such as
\"~/src/whk/mylisp/target/debug/nest\"."
  :type 'string
  :group 'brood)

(defcustom brood-program-args nil
  "Extra command-line arguments passed to `brood-program-name'."
  :type '(repeat string)
  :group 'brood)

(defun brood--program (name)
  "Return program NAME, expanded if it looks like a file path."
  (if (string-search "/" name)
      (expand-file-name name)
    name))

(defun brood--project-root (start)
  "Return the nearest ancestor of START containing a `project.blsp', or nil."
  (and start (locate-dominating-file start "project.blsp")))

;;; Inferior REPL (comint)

(defcustom inferior-brood-mode-hook nil
  "Hook for customizing `inferior-brood-mode'."
  :type 'hook
  :group 'brood)

(defcustom inferior-brood-filter-regexp "\\`\\s *\\S ?\\S ?\\s *\\'"
  "Input matching this regexp is not saved on the history list.
Defaults to a regexp ignoring all inputs of 0, 1, or 2 letters."
  :type 'regexp
  :group 'brood)

(defvar inferior-brood-buffer nil
  "The current inferior Brood process buffer.

To run multiple Brood processes, start the first with \\[run-brood], rename
its `*brood*' buffer, then set this variable to that name in the source
buffers whose `brood-send-*' commands should target it.")

(defvar inferior-brood-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "\C-x\C-e" #'brood-send-last-sexp)   ; gnu convention
    (define-key m "\M-\C-x"  #'brood-send-definition)  ; gnu convention
    (define-key m "\C-c\C-l" #'brood-load-file)
    m)
  "Keymap for `inferior-brood-mode'.")

(define-derived-mode inferior-brood-mode comint-mode "Inferior Brood"
  "Major mode for interacting with an inferior Brood process.

\\{inferior-brood-mode-map}

A Brood process is started with \\[run-brood].  From a `brood-mode' source
buffer you can send code to it with the `brood-send-*' commands.

Entry runs the hooks `comint-mode-hook' and `inferior-brood-mode-hook'."
  ;; The CLI's plain path emits no prompt; keep a permissive regexp anyway.
  (setq comint-prompt-regexp "^brood> *")
  (setq mode-line-process '(":%s"))
  (setq comint-input-filter #'brood-input-filter)
  (setq comint-get-old-input #'brood-get-old-input)
  ;; Edit/indent Brood in the REPL like in a source buffer.
  (set-syntax-table brood-mode-syntax-table)
  (setq-local lisp-indent-function #'brood-indent-function
              indent-line-function #'brood-indent-line))

(defun brood-input-filter (str)
  "Don't save input STR matching `inferior-brood-filter-regexp'."
  (not (string-match-p inferior-brood-filter-regexp str)))

(defun brood-get-old-input ()
  "Snarf the sexp ending at point."
  (save-excursion
    (let ((end (point)))
      (backward-sexp)
      (buffer-substring (point) end))))

(defun run-brood (cmd)
  "Run an inferior Brood process CMD, with I/O through buffer `*brood*'.
If there is a process already running in `*brood*', switch to it.
With a prefix argument, prompt to edit the command line (default is
`brood-program-name').

The process is connected through a pipe so the CLI takes its clean,
non-interactive REPL path (no `rustyline' control sequences)."
  (interactive (list (if current-prefix-arg
                         (read-string "Run Brood: " brood-program-name)
                       brood-program-name)))
  (unless (comint-check-proc "*brood*")
    (let ((cmdlist (split-string-and-unquote cmd))
          ;; A pipe, not a pty: keeps rustyline's ANSI editing out of the buffer.
          (process-connection-type nil))
      (set-buffer (apply #'make-comint "brood" (car cmdlist) nil
                         (append (cdr cmdlist) brood-program-args)))
      (inferior-brood-mode)
      ;; The plain REPL prints no banner of its own.
      (goto-char (point-max))
      (insert (format ";; Brood REPL — %s\n" cmd))
      (set-marker (process-mark (get-buffer-process (current-buffer))) (point))))
  (setq brood-program-name cmd)
  (setq inferior-brood-buffer "*brood*")
  (pop-to-buffer "*brood*" (append display-buffer--same-window-action
                                   '((category . comint)))))

(defun brood-proc ()
  "Return the current Brood process; start one if none is running."
  (unless (and inferior-brood-buffer
               (comint-check-proc inferior-brood-buffer))
    (save-window-excursion
      (run-brood (if current-prefix-arg
                     (read-string "Run Brood: " brood-program-name)
                   brood-program-name))))
  (or (get-buffer-process (if (derived-mode-p 'inferior-brood-mode)
                              (current-buffer)
                            inferior-brood-buffer))
      (error "No current Brood process")))

(defun brood-send-region (start end)
  "Send the region between START and END to the inferior Brood process."
  (interactive "r")
  (let ((proc (brood-proc)))
    (comint-send-region proc start end)
    (comint-send-string proc "\n")))

(defun brood-send-definition ()
  "Send the current top-level definition to the inferior Brood process."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (brood-send-region (point) end))))

(defun brood-send-last-sexp ()
  "Send the sexp before point to the inferior Brood process."
  (interactive)
  (brood-send-region (save-excursion (backward-sexp) (point)) (point)))

(defun brood-send-buffer ()
  "Send the whole buffer to the inferior Brood process."
  (interactive)
  (brood-send-region (point-min) (point-max)))

(defun brood-switch-to-repl (eob-p)
  "Switch to the inferior Brood process buffer.
With prefix argument EOB-P, position cursor at end of buffer."
  (interactive "P")
  (if (and inferior-brood-buffer (get-buffer inferior-brood-buffer))
      (pop-to-buffer inferior-brood-buffer)
    (error "No current Brood process buffer; use \\[run-brood]"))
  (when eob-p
    (push-mark)
    (goto-char (point-max))))

(defun brood-send-region-and-go (start end)
  "Send the region between START and END, then switch to the process buffer."
  (interactive "r")
  (brood-send-region start end)
  (brood-switch-to-repl t))

(defun brood-send-definition-and-go ()
  "Send the current definition, then switch to the process buffer."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (brood-send-region-and-go (point) end))))

(defvar brood-prev-l/c-dir/file nil
  "Record last directory and file used in loading, for `brood-load-file'.")

(defcustom brood-source-modes '(brood-mode)
  "Major modes whose buffers `brood-load-file' will visit to find a file.
Used by the `comint-get-source' completion in `brood-load-file'."
  :type '(repeat symbol)
  :group 'brood)

(defun brood-load-file (file-name)
  "Load a Brood file FILE-NAME into the inferior Brood process.
Sends `(load \"FILE-NAME\")' to the process."
  (interactive (comint-get-source "Load Brood file: " brood-prev-l/c-dir/file
                                  brood-source-modes t))
  (comint-check-source file-name)
  (setq brood-prev-l/c-dir/file (cons (file-name-directory file-name)
                                      (file-name-nondirectory file-name)))
  (comint-send-string (brood-proc)
                      (concat "(load \"" file-name "\")\n")))

;;; Running files / tests in a compilation buffer

(defvar brood-compilation-error-regexp-alist
  ;; The CLI prints GNU `FILE:LINE:COL: message' (matched by the built-in `gnu'
  ;; element); the extra entry catches the position-less `FILE: KIND error:'
  ;; fallback so at least the file stays clickable.  See docs/tooling.md.
  '(gnu
    ("^\\([^ \t\n:]+\\.blsp\\): \\(?:parse\\|type\\|unbound\\|arity\\|runtime\\) ?error:"
     1))
  "`compilation-error-regexp-alist' for `brood-compilation-mode'.")

(define-derived-mode brood-compilation-mode compilation-mode "Brood-Compile"
  "Compilation mode for running Brood programs.
Brood prints errors as GNU `FILE:LINE:COL: message' (see docs/tooling.md),
so error locations are clickable with \\[next-error] and the mouse."
  (setq-local compilation-error-regexp-alist brood-compilation-error-regexp-alist)
  ;; Render any ANSI colour rather than showing raw escapes.
  (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t))

(defun brood--compile (program args)
  "Run PROGRAM with ARGS (a list of strings) in a compilation buffer.
PROGRAM is a program name such as `brood-program-name' or
`nest-program-name'; ARGS already includes any extra arguments.  The process
runs through a pipe, so the CLI / test runner produce clean, un-coloured text
\(they only colour a real terminal)."
  (let ((process-connection-type nil))
    (compilation-start
     (mapconcat #'shell-quote-argument
                (cons (brood--program program) args)
                " ")
     #'brood-compilation-mode)))

(defun brood-run (&optional file)
  "Run a Brood FILE with `brood-program-name' in a compilation buffer.
Error locations are clickable.  Interactively, runs the file of the
current buffer (saving it first)."
  (interactive)
  (let ((file (or file (buffer-file-name))))
    (unless file (user-error "Buffer is not visiting a file"))
    (when (and (buffer-file-name) (buffer-modified-p)) (save-buffer))
    (let ((default-directory (or (brood--project-root file)
                                 (file-name-directory file))))
      (brood--compile brood-program-name
                      (append brood-program-args
                              (list (expand-file-name file)))))))

(defun brood-test ()
  "Run the current Brood project's tests with `nest test' in a compilation buffer.
`nest' discovers `tests/**/*_test.blsp', runs the suite once, and reports
failures as GNU `FILE:LINE:COL: message' blocks that \\[next-error] can jump
to (see docs/tooling.md)."
  (interactive)
  (let ((default-directory (or (brood--project-root
                                (or buffer-file-name default-directory))
                               default-directory)))
    (brood--compile nest-program-name '("test"))))

(defun brood-new (name)
  "Scaffold a new Brood project NAME with `nest new' (ADR-028).
Creates NAME/ with `project.blsp', `src/' and `tests/' under the current
directory."
  (interactive "sNew Brood project name: ")
  (brood--compile nest-program-name (list "new" name)))

(defun brood-doc (&optional module)
  "Emit Markdown docs for the current project with `nest doc'.
With a prefix argument, prompt for a MODULE name to document just that
module (a baked-in std module, or one on `load-path') instead of the whole
project."
  (interactive
   (list (when current-prefix-arg
           (read-string "Module (blank = whole project): "))))
  (let ((default-directory (or (brood--project-root
                                (or buffer-file-name default-directory))
                               default-directory)))
    (brood--compile nest-program-name
                    (if (and module (not (string-empty-p module)))
                        (list "doc" module)
                      '("doc")))))

;;; Jumping between a source file and its test

(defun brood--counterpart-file (file)
  "Return FILE's source/test counterpart path, or nil if undecidable.
Maps `<root>/src/REL.blsp' <-> `<root>/tests/REL_test.blsp', resolved against
the project root (nearest `project.blsp').  Returns nil when FILE is not under
the project's `src/' or `tests/' tree."
  (when-let* ((file (expand-file-name file))
              (root (brood--project-root file)))
    (let* ((src-dir  (file-name-as-directory (expand-file-name "src" root)))
           (test-dir (file-name-as-directory (expand-file-name "tests" root))))
      (cond
       ((string-prefix-p src-dir file)
        (let ((base (file-name-sans-extension (file-relative-name file src-dir))))
          (expand-file-name (concat base "_test.blsp") test-dir)))
       ((string-prefix-p test-dir file)
        (let* ((base (file-name-sans-extension (file-relative-name file test-dir)))
               (base (if (string-suffix-p "_test" base)
                         (substring base 0 (- (length "_test")))
                       base)))
          (expand-file-name (concat base ".blsp") src-dir)))))))

(defun brood-toggle-test ()
  "Jump between a Brood source file and its test, and back.
`src/REL.blsp' <-> `tests/REL_test.blsp', resolved against the project root.
If the counterpart does not exist yet, offer to create it (and its directory)."
  (interactive)
  (let* ((file  (or buffer-file-name
                    (user-error "Buffer is not visiting a file")))
         (other (or (brood--counterpart-file file)
                    (user-error "Not under the project's `src/' or `tests/' tree"))))
    (if (file-exists-p other)
        (find-file other)
      (when (y-or-n-p (format "Create %s? " (abbreviate-file-name other)))
        (make-directory (file-name-directory other) t)
        (find-file other)))))

;;; Formatting — the canonical `std/format.blsp' formatter
;;
;; `nest format' reformats every `.blsp' in a project in place; it has no
;; single-file or stdin mode, and `brood' has no `--eval' flag.  To format the
;; current buffer (including unsaved edits) with byte-identical output, we run
;; `brood-program-name' on a tiny generated driver that calls the in-language
;; `format/format-file' on a temp copy of the buffer, then read the rewritten
;; copy back.  Because it is the very same `std/format.blsp' code that backs
;; `nest format', the result is on par with it by construction — TAB/auto-indent
;; only approximates the layout (see `brood-indent-function'); this is exact.

(defcustom brood-format-on-save nil
  "Whether to reformat a `brood-mode' buffer before saving it.
When non-nil the canonical formatter runs from `before-save-hook',
buffer-locally.  A formatter error
\(or a missing `brood' binary) is reported but never blocks the save."
  :type 'boolean
  :group 'brood)

(defun brood--format-string (text)
  "Return TEXT formatted by Brood's canonical formatter, or signal an error.
Runs `brood-program-name' on a generated driver that calls
`format/format-file', so the output matches `nest format' byte-for-byte.
A parse error in TEXT is preserved verbatim by the formatter (it re-emits
unparseable spans as-is) rather than raising."
  (let ((src (make-temp-file "brood-fmt-" nil ".blsp"))
        (drv (make-temp-file "brood-fmtdrv-" nil ".blsp"))
        (errf (make-temp-file "brood-fmterr-"))
        (coding-system-for-write 'utf-8-unix)
        (coding-system-for-read 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file src (insert text))
          (with-temp-file drv
            (insert (format "(require 'format)\n(format/format-file %S)\n" src)))
          (let ((status (call-process (brood--program brood-program-name)
                                      nil (list nil errf) nil drv)))
            (unless (eq status 0)
              (error "Brood formatter failed: %s"
                     (with-temp-buffer
                       (insert-file-contents errf)
                       (string-trim (buffer-string)))))
            (with-temp-buffer
              (insert-file-contents src)
              (buffer-string))))
      (delete-file src)
      (delete-file drv)
      (delete-file errf))))

(defun brood-format-buffer ()
  "Reformat the whole buffer with Brood's canonical formatter.
Produces the same output as `nest format' on this file.  Point and the
window's scroll position are preserved, and the buffer is left unchanged if
it is already formatted (so the undo history and modified flag are clean)."
  (interactive)
  (let* ((original (buffer-string))
         (formatted (brood--format-string original)))
    (if (string-equal original formatted)
        (when (called-interactively-p 'interactive)
          (message "Already formatted"))
      (let ((pos (point))
            (start (window-start)))
        (replace-region-contents (point-min) (point-max) (lambda () formatted))
        (goto-char (min pos (point-max)))
        (when start (set-window-start (selected-window) start))))))

(defun brood--maybe-format-on-save ()
  "Reformat before saving when `brood-format-on-save' is set.
Used in `before-save-hook'.  Never blocks the save: a formatter error is
demoted to a message."
  (when brood-format-on-save
    (condition-case err
        (brood-format-buffer)
      (error (message "brood-format-on-save: %s" (error-message-string err))))))

;;; Eglot (LSP) integration
;;
;; Register the `brood-lsp' server (crates/lsp, the `brood-lsp' binary) with
;; Eglot so Brood editing gets diagnostics, completion, hover, signature help,
;; a document outline, find-references, document-highlight, rename, semantic
;; tokens, inlay hints, and go-to-definition (in-file, cross-module, into the
;; standard library, and to a `require'd module's file) through one server that
;; owns the language knowledge — see docs/lsp.md.
;;
;; Inlay hints carry two things: parameter names at call sites, and the type the
;; checker *infers* for each `defn' you have not written a `(sig ...)' for,
;; rendered after its parameter list.  Eglot draws them in `eglot-inlay-hint-face'
;; (a `shadow' derivative), which is the subtlety they want; `M-x
;; eglot-inlay-hints-mode' toggles them per buffer.  The companion code action,
;; "Declare signature", writes the inferred one into the file as a real `sig'.  The contact is a function so a later customization
;; of `brood-eglot-server-program' is honoured at connect time.  If the binary
;; isn't built / on PATH yet, `eglot-ensure' (below) just warns rather than
;; erroring, so editing still works without it.

(defcustom brood-eglot-server-program '("brood-lsp")
  "Command (program plus args) Eglot runs as the Brood language server.
A list whose car is the `brood-lsp' binary.  If it is not on your PATH (common
during development), set the car to a build, e.g.
\"~/src/whk/mylisp/target/debug/brood-lsp\"."
  :type '(repeat string)
  :group 'brood)

(defun brood--eglot-contact (&rest _)
  "Return the Brood language-server contact for Eglot.
The car of `brood-eglot-server-program', expanded if it looks like a path."
  (cons (brood--program (car brood-eglot-server-program))
        (cdr brood-eglot-server-program)))

;; Declared, not required: the `with-eval-after-load' body runs only once Eglot
;; is loaded, and this keeps a byte-compile of this file alone from reading the
;; reference as a free variable.
(defvar eglot-server-programs)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(brood-mode . brood--eglot-contact)))

;; Auto-connect: every `brood-mode' buffer tries to start the server.
;; `eglot-ensure' is autoloaded and a no-op once a session is live, so opening
;; several Brood files shares one server; if `brood-lsp' isn't found yet it warns
;; once rather than erroring.
(add-hook 'brood-mode-hook #'eglot-ensure)

(defun brood-eglot ()
  "Start Eglot for this Brood buffer, loading Eglot first.
A thin wrapper around \\[eglot] using `brood-eglot-server-program'."
  (interactive)
  (require 'eglot)
  (call-interactively #'eglot))

;;; Mode definition

(defvar-keymap brood-mode-map
  :doc "Keymap for Brood mode.
All commands in `lisp-mode-shared-map' are inherited by this map."
  :parent lisp-mode-shared-map
  ;; Evaluate code in an inferior Brood process (started on demand).
  "C-x C-e" #'brood-send-last-sexp        ; gnu convention
  "C-M-x"   #'brood-send-definition        ; gnu convention
  "C-c C-e" #'brood-send-definition
  "C-c M-e" #'brood-send-definition-and-go
  "C-c C-r" #'brood-send-region
  "C-c M-r" #'brood-send-region-and-go
  "C-c C-b" #'brood-send-buffer
  "C-c C-l" #'brood-load-file
  "C-c C-z" #'brood-switch-to-repl
  ;; Run a file / the test suite in a compilation buffer (clickable errors).
  "C-c C-c" #'brood-run
  "C-c C-t" #'brood-test
  ;; Reformat the buffer with the canonical formatter.
  "C-c C-f" #'brood-format-buffer
  ;; Project tooling (`nest') and source/test navigation.
  "C-c C-n" #'brood-new
  "C-c C-d" #'brood-doc
  "C-c C-," #'brood-toggle-test)

(easy-menu-define brood-mode-menu brood-mode-map
  "Menu for Brood mode."
  '("Brood"
    ["Evaluate Last S-expression" brood-send-last-sexp]
    ["Evaluate Definition" brood-send-definition]
    ["Evaluate Definition & Go" brood-send-definition-and-go]
    ["Evaluate Region" brood-send-region :enable mark-active]
    ["Evaluate Region & Go" brood-send-region-and-go :enable mark-active]
    ["Evaluate Buffer" brood-send-buffer]
    "--"
    ["Jump to Test/Source" brood-toggle-test]
    ["Format Buffer" brood-format-buffer]
    "--"
    ["Run File (compile)" brood-run]
    ["Run Project Tests (nest)" brood-test]
    ["Generate Docs (nest)" brood-doc]
    ["New Project... (nest)" brood-new]
    "--"
    ["Start LSP Server (Eglot)" brood-eglot]
    "--"
    ["Load Brood File..." brood-load-file]
    ["Switch to REPL" brood-switch-to-repl]
    ["Run Brood REPL" run-brood]
    "--"
    ["Indent Line" indent-for-tab-command]
    ["Indent Region" indent-region :enable mark-active]
    ["Comment Out Region" comment-region :enable mark-active]))

;;;###autoload
(define-derived-mode brood-mode lisp-data-mode "Brood"
  "Major mode for editing Brood code.
Editing commands are similar to those of `lisp-mode'.

\\{brood-mode-map}"
  :syntax-table brood-mode-syntax-table
  :abbrev-table brood-mode-abbrev-table
  (setq-local comment-start ";"
              comment-start-skip ";+[ \t]*"
              comment-add 1
              comment-use-syntax t
              parse-sexp-ignore-comments t)
  (setq-local lisp-indent-function #'brood-indent-function
              indent-line-function #'brood-indent-line
              ;; `lisp-indent-region' would re-apply Emacs' comment conventions
              ;; that `brood-indent-line' exists to avoid; nil makes
              ;; `indent-region' go line by line through it.
              indent-region-function nil
              ;; `nest format' indents with spaces only — a tab in a .blsp file
              ;; is never what the canonical layout would have written.
              indent-tabs-mode nil)
  (setq-local imenu-case-fold-search t
              imenu-generic-expression brood-imenu-generic-expression
              imenu-syntax-alist '(("+-*/.<>=?!$%_&~^:" . "w")))
  (setq-local add-log-current-defun-function #'lisp-current-defun-name)
  ;; Optional reformat-before-save with the canonical formatter (off by default).
  (add-hook 'before-save-hook #'brood--maybe-format-on-save nil t)
  ;; Eldoc: the `brood-lsp' server sends a symbol's signature *and* its docstring
  ;; on hover, but Eglot also feeds signature help into eldoc — and the default
  ;; strategy shows only the first source, so the docstring can get hidden behind
  ;; the bare signature.  Compose every source and let the echo area grow, so the
  ;; hover documentation is actually displayed (use \\[eldoc-doc-buffer] for a
  ;; scrollable view).
  (setq-local eldoc-documentation-strategy #'eldoc-documentation-compose
              eldoc-echo-area-use-multiline-p t)
  (setq-local font-lock-defaults
              '((brood-font-lock-keywords)
                nil nil nil nil
                (font-lock-mark-block-function . mark-defun)
                (font-lock-syntactic-face-function
                 . brood-font-lock-syntactic-face-function))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.blsp\\'" . brood-mode))

;;; BML — Hatch's HTML-flavoured template surface (`.bml')
;;
;; A `.bml' file is HTML plus `{expr}' interpolation and the `:if'/`:for'
;; directive attributes; it compiles to Brood Hiccup (`web/bml').  This mode
;; fontifies the markup and reuses `brood-font-lock-keywords' for the Brood
;; expressions embedded in `{…}' — the font-lock counterpart to the
;; tree-sitter grammar's brood-into-`{…}' injection.

(defvar brood-bml-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Lists/vectors/maps balance for navigation inside interpolations.
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?{  "(}" st)
    (modify-syntax-entry ?}  "){" st)
    ;; Strings: HTML attribute values and Brood strings inside `{…}'.
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    ;; Tag/attribute punctuation.  `;' is punctuation, not a comment — it
    ;; occurs in inline CSS (`style="…;…"').
    (dolist (ch '(?< ?> ?/ ?= ?\;))
      (modify-syntax-entry ch "." st))
    ;; Brood symbol constituents so `{…}' expressions read as in `brood-mode'
    ;; (kebab-case names, `:keywords', predicate suffixes).
    (dolist (ch '(?+ ?- ?* ?! ?? ?% ?_ ?& ?^ ?. ?:))
      (modify-syntax-entry ch "_" st))
    st)
  "Syntax table for `brood-bml-mode'.")

(defvar brood-bml-font-lock-keywords
  (append
   (list
    ;; HTML comments.
    '("<!--\\(?:.\\|\n\\)*?-->" 0 font-lock-comment-face t)
    ;; Component tags:  <.name …  and  </.name>  → a type face, to set them apart.
    '("</?\\.\\([a-zA-Z][a-zA-Z0-9/_-]*\\)" 1 font-lock-type-face)
    ;; Tag names:  <tag …  and  </tag>.
    '("</?\\([a-zA-Z][a-zA-Z0-9-]*\\)" 1 font-lock-function-name-face)
    ;; Directive attributes (`:if'/`:for') — highlighted before the generic
    ;; attribute rule so they read as control keywords.
    '("\\(:\\(?:if\\|for\\)\\)[ \t]*=" 1 font-lock-keyword-face)
    ;; Attribute names: an identifier immediately before `='.
    '("\\([a-zA-Z_:][a-zA-Z0-9_:-]*\\)[ \t]*=" 1 font-lock-variable-name-face)
    ;; `@name' assign shorthand — (get model :name) inside `{…}'.
    '("@[a-zA-Z_][a-zA-Z0-9_?!-]*" 0 font-lock-variable-name-face)
    ;; Interpolation braces.
    '("[{}]" 0 font-lock-preprocessor-face))
   ;; Embedded Brood: special forms, def heads, `:keywords', constants — the
   ;; same rules `brood-mode' uses, applied inside `{…}'.
   brood-font-lock-keywords)
  "Font-lock for `brood-bml-mode': HTML markup plus embedded Brood in {…}.")

;;;###autoload
(define-derived-mode brood-bml-mode prog-mode "Brood-BML"
  "Major mode for editing BML templates — Hatch's HTML-flavoured template surface.
Highlights HTML markup and the Brood expressions embedded in `{…}'
interpolations (compiled to Hiccup by `web/bml').

\\{brood-bml-mode-map}"
  :syntax-table brood-bml-mode-syntax-table
  (setq-local comment-start "<!-- "
              comment-end " -->"
              comment-start-skip "<!--[ \t]*")
  (setq-local font-lock-defaults '((brood-bml-font-lock-keywords))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.bml\\'" . brood-bml-mode))

(provide 'brood)

;;; brood.el ends here

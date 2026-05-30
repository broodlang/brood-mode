# brood-mode

An Emacs major mode for editing [Brood](https://github.com/broodlang) — a small,
dynamically-typed Lisp-1 implemented in Rust. Brood source files use the `.blsp`
extension.

`brood-mode` derives from `lisp-data-mode`, so it inherits Emacs' full
s-expression machinery (navigation, electric pairs, `forward-sexp`, structural
editing) and adds Brood-specific syntax, font-lock, and indentation. It also
bundles the process integration in one file:

- **`run-brood`** — an inferior Brood REPL over comint.
- **`brood-send-*`** — evaluate the last sexp / definition / region / buffer in
  the REPL (like `eval-last-sexp` for Elisp).
- **`brood-run`** — run the current file with `brood` in a compilation buffer
  where Brood's GNU `FILE:LINE:COL: message` diagnostics are clickable.
- **`brood-test` / `brood-new` / `brood-doc`** — drive the `nest` project tool
  to run the suite, scaffold a project, or emit Markdown docs.
- **`brood-toggle-test`** — jump between a source file and its test
  (`src/foo.blsp` ↔ `tests/foo_test.blsp`).
- **`brood-format-buffer`** — reformat the buffer with Brood's canonical
  formatter (`std/format.blsp`, the same code `nest format` runs), for output
  byte-identical to it. TAB/auto-indent approximates that layout; this command
  is exact. Set `brood-format-on-save` to reformat automatically on save.
- **Eglot/LSP** — registers the `brood-lsp` language server (diagnostics,
  completion, hover, signature help, document outline, find-references, rename,
  semantic tokens, go-to-definition). `brood-mode` enables Eglot automatically;
  if `brood-lsp` isn't on `PATH` it just warns once.

## Requirements

- **Emacs 29.1 or newer** (uses `defvar-keymap`).
- The Brood toolchain binaries (`brood`, `nest`, `brood-lsp`) for the REPL,
  project, and LSP commands. These are optional for plain editing, and need not
  be on `PATH` — point the mode at a build (see [Configuration](#configuration)).

## Installation

### use-package with `:vc` (Emacs 30+, or use-package 2.x with package-vc)

```elisp
(use-package brood
  :vc (:url "https://github.com/broodlang/brood-mode"
       :rev :newest)
  :mode ("\\.blsp\\'" . brood-mode))
```

On Emacs 29, install the package once with `M-x package-vc-install RET
https://github.com/broodlang/brood-mode RET`, then use the plain
`(use-package brood ...)` form below.

### use-package + straight.el

```elisp
(use-package brood
  :straight (brood :type git :host github :repo "broodlang/brood-mode")
  :mode ("\\.blsp\\'" . brood-mode))
```

### use-package + elpaca

```elisp
(use-package brood
  :ensure (:host github :repo "broodlang/brood-mode")
  :mode ("\\.blsp\\'" . brood-mode))
```

### Manual

Clone the repo and put `brood.el` on your `load-path`:

```sh
git clone https://github.com/broodlang/brood-mode ~/.emacs.d/site-lisp/brood-mode
```

```elisp
(use-package brood
  :load-path "~/.emacs.d/site-lisp/brood-mode"
  :mode ("\\.blsp\\'" . brood-mode))
```

> The package's feature is `brood` (the file is `brood.el`), so you
> `(require 'brood)` / `(use-package brood …)` even though the repository is
> named `brood-mode`. An autoload registers `brood-mode` for `.blsp` files, so
> the explicit `:mode` line above is optional once the package is installed.

## Configuration

During language development the `brood`, `nest`, and `brood-lsp` binaries are
usually not on `PATH`. Point the mode at your build:

```elisp
(use-package brood
  :vc (:url "https://github.com/broodlang/brood-mode" :rev :newest)
  :custom
  (brood-program-name       "~/src/whk/brood/target/release/brood")
  (nest-program-name        "~/src/whk/brood/target/release/nest")
  (brood-eglot-server-program '("~/src/whk/brood/target/release/brood-lsp")))
```

A path containing `/` is expanded automatically, so `~`-relative builds work.

## Formatting

There are two layers, and they agree:

- **Auto-indent (TAB, `indent-region`, electric newline)** mirrors the
  formatter's layout policy from `std/format.blsp` — the body of every form
  indents two columns from its open paren (never aligned under the first
  argument), with a per-form count of header arguments kept on the head line.
  Re-indenting already-formatted code is a no-op, so editing doesn't fight the
  formatter. It approximates the layout; it does not perform the formatter's
  line-filling or `let`/map pair-joining.
- **`brood-format-buffer` (`C-c C-f`)** is exact. It runs your `brood` binary
  over the in-language `format/format-file`, i.e. the very code behind `nest
  format`, so the result is byte-identical to `nest format` on that file. Set
  `brood-format-on-save` to `t` to run it from `before-save-hook` (a formatter
  error or a missing `brood` binary is reported but never blocks the save).

```elisp
(use-package brood
  :vc (:url "https://github.com/broodlang/brood-mode" :rev :newest)
  :custom (brood-format-on-save t))
```

## Key bindings

Active in `brood-mode` buffers (see the **Brood** menu for the full list):

| Key       | Command                        |
|-----------|--------------------------------|
| `C-x C-e` | `brood-send-last-sexp`         |
| `C-M-x`   | `brood-send-definition`        |
| `C-c C-e` | `brood-send-definition`        |
| `C-c C-r` | `brood-send-region`            |
| `C-c C-b` | `brood-send-buffer`            |
| `C-c C-z` | `brood-switch-to-repl`         |
| `C-c C-l` | `brood-load-file`              |
| `C-c C-c` | `brood-run` (file, compile)    |
| `C-c C-t` | `brood-test` (`nest test`)     |
| `C-c C-f` | `brood-format-buffer`          |
| `C-c C-n` | `brood-new`  (`nest new`)      |
| `C-c C-d` | `brood-doc`  (`nest doc`)      |
| `C-c C-,` | `brood-toggle-test`            |

`M-x run-brood` starts the REPL; `M-x brood-eglot` starts the language server
explicitly (it also starts automatically when you open a `.blsp` file, if
`brood-lsp` is available).

## License

GPL-3.0-or-later. This mode is also distributed as part of GNU Emacs.

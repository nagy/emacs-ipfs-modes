# AGENTS.md — emacs-ipfs-modes

## Purpose

Emacs Lisp package for working with IPFS data in Emacs.  `cid-mode`
decodes and browses IPFS Content Identifiers.  `ol-cid.el` adds an Org
link type and `embark-cid.el` adds Embark actions.  The runtime floor
Emacs 30.1.  The license AGPL-3.0-or-later.  Users install, configure
and key-bind the package from `README.org`.

## Layout

- `cid-mode.el` — the only entry library.  It owns decoding, the
  `cid-mode` renderer, the commands, the bookmark handler and the
  `ipfs://`/`ipns://` URL handlers.
- `ol-cid.el` — Org link type `cid:`.  Optional module.
- `embark-cid.el` — Embark target finder and actions for CIDs.
  Optional module.
- `test/` — ERT suite and the shared fixtures.
- `nix/emacs-screenshot.nix` — the README screenshot derivation.
- `flake.nix` — package, checks, dev shell, formatter.

## Build and test

- `nix flake check` — the gate: build, ERT suite and lint.
- ERT alone, for a fast loop:
  `emacs -Q --batch -L . -L test -l test/cid-mode-test.el -f ert-run-tests-batch-and-exit`
- `nix build .#checks.x86_64-linux.lint` — package-lint and checkdoc
  only.
- `nix build .#screenshot --out-link /tmp/screenshot` — regenerate the
  README image.
- `nix fmt` — formats the Nix files.  Lisp has no formatter here.
- `nix develop` — Emacs and nix in the shell.

## Architecture

```
CID string
  -> cid--detect-prefix   (v0: no prefix, v1: multibase prefix)
  -> cid--decode-base     (bytes)
  -> cid--parse-v0 / cid--parse-v1   (varint framing)
  -> cid-info struct
  -> cid--display -> cid--render     (tree from cid-sections-hook)
```

### `cid-mode.el`

The decode layer takes a string and returns a `cid-info` struct.  It
touches no buffer.  The display layer owns the buffer: `cid--render`
erases, runs `cid-sections-hook`, restores the folds and the point.
`cid--display` wraps the render in `cid--unless-rendered`, keyed on the
data and the hook.

A new data group reads `cid--info` and calls `magit-insert-section`
with a `cid-section` and `cid--insert-field` leaves.  The decode layer
knows nothing about sections, and the inserters never decode.

### `ol-cid.el` and `embark-cid.el`

Both modules sit on top of `cid-mode` and call its public commands and
shared helpers only.  Neither module loads the other.  A missing
module stays quiet: `cid-mode.el` defers the Org require with
`(require 'ol-cid nil t)`, and the Embark registration runs from the
autoloads file.

### CID framing

A CIDv0 string holds a bare multihash.  The base58btc encoding, the
dag-pb codec and version 0 stay implicit.  A CIDv1 string starts with a
multibase prefix, then carries the version, codec and multihash
varints.

## Rules

### Package identity

- Keep `pname`, the file name, the provided feature and the mode name
  at `cid-mode`.  `use-package cid-mode` resolves all three.
- Give every user-facing command an `;;;###autoload` cookie.  The ERT
  tests `cid-autoloads` and `embark-cid-autoloads` check them.

### Rendering

- Do not edit a `cid-mode` buffer after `cid--render`.  Section
  positions stay plain integers, so an edit leaves them stale.
- Do not give a CID section a lazy body.  With
  `magit-section-inhibit-markers` set, `magit-insert-section-body`
  signals `markerp`.
- Do not put a count or a size into a section value.  The value is the
  ident that carries the fold and the point record.
- Do not signal from a section inserter on bad input.  Push a message
  onto `cid-info-errors` and let `cid-insert-warnings-section` show it.

### Dependencies and load order

- Load `ol-cid` only through `(require 'ol-cid nil t)`.  Users without
  Org must not pay for it.
- Use `declare-function` only for a target that carries an autoload
  cookie.  Load the package for a private helper.
- Declare `(side-effect-free t)` on a function that reads its arguments
  only, and add `(pure t)` when the result depends on constants alone.

### Build gate

- Never silence a byte-compile warning.  Fix it.
- Do not silence the lint gate.  A new prefix family belongs in
  `package-lint--sane-prefixes`, not in a blanket disable.

## Conventions

- Spell the CID character class with `(char "A-Za-z0-9")` inside `rx`.
  `package-lint` reads a bare `any` as an Emacs 31 alias.
- Prefix a private function with `cid--`.  `magit-cid` and `embark-cid`
  own their own namespaces in the lint gate.
- Order `require` forms: built-ins alphabetically, then `cl-lib`, then
  `magit-section`.
- Build a keymap with `defvar-keymap` and an explicit `:parent`.  Let
  magit-section find a per-type keymap through the
  `magit-<type>-section-map` name.  Do not call `define-key` by hand.
- Use `let*` when one binding reads an earlier one.  Plain `let` under
  `lexical-binding` can not.
- Document every argument in a docstring.  `checkdoc` gates the build.
- Use the `cl-` prefixed name of a standard function.  `melpaBuild`
  can not resolve the bare name from `cl-extra`.
- Write the reason for a non-obvious choice into a comment next to the
  code.  `cid-mode.el`, `flake.nix` and `nix/emacs-screenshot.nix`
  carry their own load-bearing comments.

## Testing

- One file per source unit, named `test/<unit>-test.el`.
- Put a shared fixture into `test/cid-mode-test-helper.el`.  The
  `-helper` name keeps the file out of the `test/*-test.el` glob that
  the flake loads, so only real tests run.
- Ship a test with every behavior change.  The suite runs inside
  `nix flake check`.
- Read the section tree, not the buffer text.  Use
  `cid-test--with-buffer`, `cid-test--section`, `cid-test--root-values`
  and `cid-test--render-alpha`, and assert through
  `(oref section type)`, `(oref section value)` and
  `(eq section old-section)`.
- Reach a folded section through a heading search.  `search-forward`
  skips invisible text.
- Wrap a hand-written insert in `(let ((inhibit-read-only t)) ...)`.
  The mode body makes the buffer read-only.
- Keep the known test vectors as constants at the top of
  `cid-mode-test.el`.

## Dependencies

|Dependency    |Required?|Why                                             |
|--------------|---------|------------------------------------------------|
|Emacs 30.1    |yes      |`cl-defstruct`, `defvar-keymap`, `string-replace`|
|magit-section |yes      |the section tree and its keymaps                |
|ol (org)      |soft     |`ol-cid.el`                                     |
|embark        |soft     |`embark-cid.el`                                 |

`melpaBuild` adds only `share/emacs/site-lisp` to `load-path`, so the
`elpa/<pkg>-<version>` directory of a requirement never arrives by
itself.  The flake builds against a wrapped Emacs that carries
magit-section and its closure.

## Open work

- Add `dag-mode` to browse IPLD DAG nodes by following links in
  dag-pb and dag-cbor content.
- Add `ipfs-mode` to control an IPFS node: peers, pinning, files.
- Add `ipns-mode` to browse IPNS records and keys.

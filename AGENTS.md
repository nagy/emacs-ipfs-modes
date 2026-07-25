# AGENTS.md — emacs-ipfs-modes

## Overview

Emacs package for working with IPFS data from within Emacs.  The
initial offering is `cid-mode`, a major mode for decoding and
browsing IPFS Content Identifiers (CIDs), similar to the online tool
at <https://cid.ipfs.tech/>.  Org link support via `ol-cid.el`.

## Files

| File | Purpose |
|---|---|
| `cid-mode.el` | CID decoder major mode (~622 lines) |
| `ol-cid.el` | Org link type `cid:` for CID references (~90 lines) |
| `cid-tests.el` | ERT test suite (~470 lines, 57 tests) |
| `default.nix` | Nix build with `melpaBuild` |
| `shell.nix` | Nix dev shell with Emacs and dependencies |

## Dependencies

| Dependency | Required? | Why |
|---|---|---|
| Emacs 30.1 | yes | `cl-defstruct`, `string-replace`, `defvar-keymap` |
| browse-url | built-in | `cid-open-gateway` opens the CID on an IPFS gateway |
| bookmark | built-in | `cid-bookmark-jump`, `cid--bookmark-make-record` |
| ol (org) | soft | Org link support via `ol-cid.el` (opt-in load) |

## Architecture

### `cid-mode.el` (~622 lines)

The mode is organized into these sections:

1. **Customization** — `defgroup cid`, `cid-gateway-url`, `cid-hex-bytes-per-line`
2. **Constants** — Multibase, multicodec, and multihash tables
3. **Encoding decoders** — base58btc, base32 (lower/upper/nopad), base16
4. **Varint decoder** — unsigned LEB128 used by CID framing
5. **Lookup helpers** — codec name, multihash name/size, multibase name
6. **CID parsing** — `cid-info` struct, `cid--decode-base`, `cid--detect-prefix`, `cid--parse-v0`, `cid--parse-v1`
7. **Display** — `cid-mode` (derived from `special-mode`), `cid--display` renders the decoded CID
8. **Commands** — `cid-decode`, `cid-decode-at-point`, `cid-revert`, `cid-copy-cid`, `cid-open-gateway`
9. **Bookmarks** — `cid-bookmark-jump`, `cid--bookmark-make-record`

### `ol-cid.el` (~90 lines)

Opt-in Org link module.  Defines the `cid:` link type:

- **Follow** (`cid--org-follow`) — calls `cid-decode` to show the CID
  in a `cid-mode` buffer; reuses existing buffers when available
- **Complete** (`cid--org-complete`) — prompts for a CID string when
  inserting a `cid:` link with `org-insert-link`
- **Store** (`cid--org-store-link`) — captures the current CID from a
  `cid-mode` buffer (`C-c l`)
- **Export** (`cid-org-export`) — renders as an IPFS gateway URL in
  HTML/LaTeX

Loaded by `cid-mode.el` via deferred `with-eval-after-load` (no-op if
ol-cid.el is not installed).  Users can also activate it manually:

```elisp
(with-eval-after-load 'org
  (require 'ol-cid))
```

Use the link in Org buffers:

```
[[cid:QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco][my CID]]
[[cid:bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi]]
```

### Data flow

```
CID string
  → cid--detect-prefix (v0=implicit base58btc, v1=multibase prefix)
  → cid--decode-base (bytes)
  → cid--parse-v0 / cid--parse-v1
    → decode version varint
    → decode codec varint (v1) or implicit dag-pb (v0)
    → decode multihash varint
    → extract digest bytes
  → cid-info struct
  → cid--display (render in cid-mode buffer)
```

### CIDv0 specifics

- CIDv0 strings are exactly 46 characters starting with `Qm`.
- Implicit multibase: base58btc (no prefix character).
- Implicit codec: dag-pb (0x70).
- The raw decoded bytes are just the multihash (no version/codec framing).

### CIDv1 specifics

- CIDv1 strings start with a multibase prefix character (`z`, `b`, `B`, `c`, `C`, `f`, `F`).
- Raw bytes: `[version-varint] [codec-varint] [multihash...]`.
- Version varint should be `1` (0x01).
- Codec varint identifies the content type (dag-pb, dag-cbor, raw, etc.).
- The rest is the multihash (algorithm varint + digest-size varint + digest).

## Building

```bash
# Nix (local)
nix-build -E "with import <nixpkgs> {}; (emacs.pkgs.callPackage ./. {})"

# Without Nix
emacs -Q --batch -f batch-byte-compile cid-mode.el
emacs -Q --batch -L . -f batch-byte-compile ol-cid.el
```

Byte-compile with warnings as errors (wired into the Nix build
via `turnCompilationWarningToError = true`):

```bash
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile cid-mode.el
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" \
  -L . -f batch-byte-compile ol-cid.el
```

## Testing

```bash
# Run the full test suite (57 tests):
emacs -Q --batch -L . -l cid-tests.el -f ert-run-tests-batch-and-exit

# Smoke test decode commands:
emacs -Q --batch -L . -l cid-mode.el \
  --eval '(cid-decode "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco")' \
  --eval '(cid-decode "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi")' \
  --eval '(message "All decodes OK")'
```

### Test vectors

| Vector | Type | Description |
|---|---|---|
| `QmbGtJg23skhvFmu9mJiePVByhfzu5rwo74MEkVDYAmF5T` | CIDv0 | Big Buck Bunny, sha2-256, dag-pb |
| `bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi` | CIDv1 | base32 lowercase nopad, sha2-256, dag-pb |

## Keybindings

| Key | Command | Description |
|---|---|---|
| `g` | `cid-revert` | Re-render the CID buffer |
| `w` | `cid-copy-cid` | Copy CID to kill ring |
| `b` | `cid-open-gateway` | Open CID on IPFS gateway |
| `q` | `quit-window` | Close the CID buffer (inherited from `special-mode-map`) |

## Conventions

### `defvar-keymap` with `:parent`

Keymaps use `defvar-keymap` with explicit `:parent` to inherit from
standard mode maps.  `cid-mode-map` inherits from `special-mode-map`,
which provides `q` (`quit-window`) and `g` (`revert-buffer`) for free:

```elisp
(defvar-keymap cid-mode-map
  :doc "Keymap for `cid-mode' buffers."
  :parent special-mode-map
  "g" #'cid-revert
  "w" #'cid-copy-cid
  "b" #'cid-open-gateway)
```

No manual `define-key` / `make-sparse-keymap` calls.

### `require` order

Required built-in packages come first, alphabetically, followed by
`cl-lib`:

```elisp
(require 'bookmark)
(require 'cl-lib)
```

### Derive from `special-mode`

`cid-mode` derives from `special-mode`.  This gives read-only buffers,
`q` keybinding, and standard buffer conventions for free — no manual
`read-only-mode` calls.

### `cid-info` struct

All parsed data lives in a `cl-defstruct` value.  The mode only stores
one buffer-local variable (`cid--info`), making `revert-buffer` trivial.

### Pure decoder functions

All decoding/parsing functions declare `(side-effect-free t)` where
applicable.  Only `cid--display` and the interactive commands have side
effects.

### Graceful error handling

Invalid encodings, truncated data, and unknown codes all produce
structured error messages (warnings in the display), not runtime
errors.

### `cid-decode-at-point`

Uses `skip-chars-forward/backward` and pattern matching to find CIDs
in any buffer.  CIDv0 detection is strict (exactly 46 chars starting
with `Qm`); CIDv1 detects any word starting with a known multibase
prefix, excluding characters ambiguous in base58 (`0`, `O`, `I`, `l`).

### `ol-cid` is opt-in

`cid-mode.el` uses `(with-eval-after-load 'org (require 'ol-cid nil t))`
— the `nil t` means it silently no-ops when ol-cid is not installed,
so users who don't use Org incur no cost.  `declare-function` stubs
in `ol-cid.el` handle cross-file references without hard dependencies.

### `bookmark-handler-type`

Bookmark jump functions declare their handler type for the bookmark UI:

```elisp
(put 'cid-bookmark-jump 'bookmark-handler-type "CID")
```

### Byte-compiler silencing

Cross-file function references in `ol-cid.el` use `declare-function`.
External vars from `cid-mode.el` that `ol-cid.el` references are
declared with value-less `defvar` to silence the byte-compiler without
clobbering the real value:

```elisp
(declare-function cid-decode "cid-mode")
(defvar cid--info)
```

### `cl-lib` prefix for Emacs functions

Use the `cl-` prefixed form of standard Emacs functions that have a
`cl-lib` alias.  `melpaBuild`'s isolated compilation environment does
not resolve unprefixed forms like `evenp` from `cl-extra`, even when
`cl-lib` is required.  Use `cl-evenp` instead of `evenp`:

```elisp
;; Wrong — unresolvable in melpaBuild
(when (evenp len) …)

;; Correct
(when (cl-evenp len) …)
```

### `let*` for sequential bindings

In `lexical-binding: t`, plain `let` evaluates all init forms in the
outer scope — later bindings cannot reference earlier ones.  Use
`let*` when one binding's init form depends on a prior binding.

### Display rendering

CID display uses `cl-defstruct` accessors throughout `cid--display`,
with `cl-labels`-style helpers (`cid--insert-header`,
`cid--insert-section`, `cid--insert-field`, `cid--insert-value`,
`cid--insert-hex-dump`).  These are currently top-level `defun`s
because `cid--display` is outside the mode body (modes that
use `cl-labels` inside `define-derived-mode` avoid this).

## TODO

- **`cl-labels` for display helpers** — move the five `cid--insert-*`
  helpers into `cid--display` as `cl-labels` closures.  They are only
  called from one place and don't need package-wide visibility.
- **Replace Unicode box-drawing** — the `╔═` section headings in
  `cid--insert-section` are non-standard.  Consider replacing with
  plain text section headings using `font-lock-keyword-face`.
- **`dag-mode`** — browse IPLD DAG nodes by following links in
  dag-pb/dag-cbor content
- **`ipfs-mode`** — interactive IPFS node control (peers, pinning,
  files)
- **`ipns-mode`** — browse IPNS records and keys

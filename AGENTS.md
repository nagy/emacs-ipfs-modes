# AGENTS.md — emacs-ipfs-modes

## Overview

Emacs package for working with IPFS data from within Emacs.  The
initial offering is `cid-mode`, a major mode for decoding and
browsing IPFS Content Identifiers (CIDs), similar to the online tool
at <https://cid.ipfs.tech/>.  Also includes Org link support
(`ol-cid.el`), Embark actions (`embark-cid.el`), and `ipfs://`/
`ipns://` URL scheme handlers.

## Files

| File | Purpose |
|---|---|
| `cid-mode.el` | CID decoder major mode (~809 lines) |
| `ol-cid.el` | Org link type `cid:` for CID references (~90 lines) |
| `embark-cid.el` | Embark target finder and actions for CIDs (~83 lines) |
| `cid-tests.el` | ERT test suite (~606 lines, 61 tests) |
| `default.nix` | Nix build with `melpaBuild` |
| `shell.nix` | Nix dev shell with Emacs and dependencies |

## Dependencies

| Dependency | Required? | Why |
|---|---|---|
| Emacs 30.1 | yes | `cl-defstruct`, `string-replace`, `defvar-keymap` |
| browse-url | built-in | `cid-open-gateway` opens the CID on an IPFS gateway |
| bookmark | built-in | `cid-bookmark-jump`, `cid--bookmark-make-record` |
| rx | built-in | `rx-define` for CID pattern matching |
| thingatpt | built-in | `thing-at-point` integration for `cid` type |
| ol (org) | soft | Org link support via `ol-cid.el` (opt-in load) |
| embark | soft | Embark actions via `embark-cid.el` (opt-in load) |

## Architecture

### `cid-mode.el` (~809 lines)

The mode is organized into these sections:

1. **Customization** — `defgroup cid`, `cid-gateway-url`,
   `cid-hex-bytes-per-line`, faces (`cid-header-face`,
   `cid-section-face`, `cid-field-face`)
2. **Constants** — Multibase, multicodec, and multihash tables
   (canonical names from the `go-multicodec` / `go-multibase` tables
   vendored in the IPFS Kubo source)
3. **Rx patterns** — `cid-char`, `cid-v0`, `cid-v0-strict`,
   `cid-v1-ambiguous`, `cid-v1-word` (compiled `rx-define` patterns
   for CID detection; avoids inline regex strings in `string-match-p`)
4. **Encoding decoders** — base58btc, base32 (lower/upper/nopad), base16
5. **Encoding encoders** — base58btc, base32 (for conversion display)
6. **Varint decoder** — unsigned LEB128 used by CID framing
7. **Lookup helpers & conversion** — codec name/description,
   multihash name/size, multibase name, `cid--cidv0-to-v1`,
   `cid--cidv1-to-v0`
8. **CID parsing** — `cid-info` struct, `cid--decode-base`,
   `cid--detect-prefix`, `cid--parse-v0`, `cid--parse-v1`
9. **Display** — summary line (like cid.ipfs.tech), Identity section
   with codec description, Multihash section with bits and digest in
   base58btc, Sizes section, Raw Bytes hex dump, CIDv0↔v1 conversion
10. **Commands** — `cid-decode`, `cid-decode-at-point`, `cid-revert`,
    `cid-copy-cid`, `cid-open-gateway`
11. **Bookmarks** — `cid-bookmark-jump`, `cid--bookmark-make-record`
12. **URL scheme handlers** — `cid--browse-ipfs` registers `ipfs://`
    and `ipns://` handlers via `browse-url-default-handlers`

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

### `embark-cid.el` (~83 lines)

Opt-in Embark module.  Registers `ipfs-cid` as a target type:

- **Target finder** (`embark-cid-target-at-point`) — delegates to
  `cid--bounds`, returns `(ipfs-cid CID START . END)`
- **Actions** — `RET` (decode in `cid-mode`), `w` (copy to kill ring),
  `b` (open on IPFS gateway)

Loaded by user with `(require 'embark-cid)`.

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
    → summary line
    → identity + codec description
    → multihash + digest (hex + base58btc) + bits
    → sizes (CID string bytes, binary bytes)
    → raw bytes hex dump
    → CIDv0→v1 or v1→v0 conversion
```

### CIDv0 specifics

- CIDv0 strings are exactly 46 characters starting with `Qm`.
- Implicit multibase: base58btc (no prefix character).
- Implicit codec: dag-pb (0x70).
- The raw decoded bytes are just the multihash (no version/codec framing).

### CIDv1 specifics

- CIDv1 strings start with a multibase prefix character
  (`z`=base58btc, `b`=base32, `B`=base32upper, `c`=base32pad,
  `C`=base32padupper, `f`=base16, `F`=base16upper, `m`=base64,
  `u`=base64url, `M`=base64pad, `U`=base64urlpad).
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
emacs -Q --batch -L . -f batch-byte-compile embark-cid.el
```

Byte-compile with warnings as errors (wired into the Nix build
via `turnCompilationWarningToError = true`):

```bash
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile cid-mode.el
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" \
  -L . -f batch-byte-compile ol-cid.el
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" \
  -L . -f batch-byte-compile embark-cid.el
```

## Testing

```bash
# Run the full test suite (61 tests):
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

### Embark keybindings (`embark-cid-map`)

| Key | Command | Description |
|---|---|---|
| `RET` | `embark-cid-decode` | Decode CID in `cid-mode` buffer |
| `w` | `embark-cid-copy` | Copy CID to kill ring |
| `b` | `embark-cid-open-gateway` | Open CID on IPFS gateway |

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
(require 'browse-url)
(require 'cl-lib)
(require 'rx)
(require 'thingatpt)
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

Uses `skip-chars-forward/backward` and `rx`-compiled patterns to find
CIDs in any buffer.  CIDv0 detection is strict (exactly 46 base58
chars starting with `Qm`); CIDv1 detects any word starting with a
known multibase prefix, excluding characters ambiguous in base58
(`0`, `O`, `I`, `l`).  The `rx` patterns are defined once at
compile time with `rx-define` and referenced via `(rx cid-v0)` etc.,
avoiding inline regex strings in `string-match-p`.

### `thing-at-point` integration

`cid-mode.el` registers a `cid` thing type via:

```elisp
(put 'cid 'bounds-of-thing-at-point #'cid--bounds)
(put 'cid 'thing-at-point #'cid--thing-at-point)
```

This lets `(thing-at-point 'cid)` and `(bounds-of-thing-at-point 'cid)`
work in any buffer, not just `cid-mode` buffers.  `cid--thing-at-point`
wraps `cid--bounds` with `when-let*` and extracts the string.

### `browse-url` scheme handlers

The `ipfs://` and `ipns://` URL schemes are registered in
`browse-url-default-handlers` (not the user-reserved
`browse-url-handlers`).  The handler `cid--browse-ipfs` extracts
the CID or IPNS name and opens it on the configured gateway.
Registered via `with-eval-after-load 'browse-url` so it only
activates when `browse-url` is actually loaded.

### Gateway fallback

`cid-gateway-url` is resolved in this order:

1. The `cid-gateway-url` defcustom value
2. The `IPFS_GATEWAY` environment variable
3. `https://ipfs.io` (hardcoded default)

Embark actions and the `ipfs://`/`ipns://` URL handler both
use `cid-gateway-url` as their gateway.

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

### `case-fold-search` for character class matches

`string-match-p` defaults to case-insensitive matching.  When matching
against a specific set of characters that includes letters, bind
`case-fold-search` to nil to avoid false positives.  The ambiguous
characters are defined once as an `rx-define` pattern:

```elisp
(rx-define cid-v1-ambiguous
  (any "0" "O" "I" "l"))

;; Wrong — also matches lowercase i and l (because I and l match)
(not (string-match-p "[0OIl]" word))

;; Correct
(not (let ((case-fold-search nil))
       (string-match-p (rx cid-v1-ambiguous) word)))
```

### Display rendering

CID display uses `cl-defstruct` accessors throughout `cid--display`,
with `cl-labels`-style helpers (`cid--insert-header`,
`cid--insert-section`, `cid--insert-field`, `cid--insert-value`,
`cid--insert-hex-dump`).  These are currently top-level `defun`s
because `cid--display` is outside the mode body (modes that
use `cl-labels` inside `define-derived-mode` avoid this).

Faces are defined as `defface` rather than inline `:inherit` props:

- `cid-header-face` — inherits `outline-1`; used for the CID string title
- `cid-section-face` — inherits `font-lock-keyword-face` + `bold`;
  used for section headings (Identity, Multihash, Sizes, etc.)
- `cid-field-face` — inherits `font-lock-type-face`; used for field
  labels (CID, Version, Multibase, etc.)

## TODO

- **`cl-labels` for display helpers** — move the five `cid--insert-*`
  helpers into `cid--display` as `cl-labels` closures.  They are only
  called from one place and don't need package-wide visibility.
- **Replace Unicode box-drawing** — the `╔═` section headings in
  `cid--insert-section` are non-standard.  Consider replacing with
  plain text section headings.
- **`dag-mode`** — browse IPLD DAG nodes by following links in
  dag-pb/dag-cbor content
- **`ipfs-mode`** — interactive IPFS node control (peers, pinning,
  files)
- **`ipns-mode`** — browse IPNS records and keys

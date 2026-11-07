# AGENTS.md — emacs-ipfs-modes

## Overview

Emacs package for working with IPFS data from within Emacs.  The
initial offering is `cid-mode`, a major mode for decoding and
browsing IPFS Content Identifiers (CIDs), similar to the online tool
at <https://cid.ipfs.tech/>.  Also includes Org link support
(`ol-cid.el`), Embark actions (`embark-cid.el`), and `ipfs://`/
`ipns://` URL scheme handlers.

## Files

|File           |Purpose                                              |
|---------------|-----------------------------------------------------|
|`cid-mode.el`  |CID decoder major mode (~917 lines)                  |
|`ol-cid.el`    |Org link type `cid:` for CID references (~88 lines)  |
|`embark-cid.el`|Embark target finder and actions for CIDs (~89 lines)|
|`cid-tests.el` |ERT test suite (~700 lines, 66 tests)                |
|`README.org`   |Install, `use-package` recipe, commands, keys, options |
|`flake.nix`    |Flake outputs; `melpaBuild` package plus screenshot wiring |
|`flake.lock`   |Pinned nixpkgs/flake-parts/nur-packages inputs       |
|`nix/emacs-screenshot.nix`|Nix expression for screenshot generation  |

## Dependencies

|Dependency   |Required?|Why                                                |
|-------------|---------|---------------------------------------------------|
|Emacs 30.1   |yes      |`cl-defstruct`, `string-replace`, `defvar-keymap`  |
|magit-section|yes      |collapsible sections via `magit-insert-section`    |
|browse-url   |built-in |`cid-open-gateway` opens the CID on an IPFS gateway|
|bookmark     |built-in |`cid-bookmark-jump`, `cid--bookmark-make-record`   |
|rx           |built-in |`rx-define` for CID pattern matching               |
|thingatpt    |built-in |`thing-at-point` integration for `cid` type        |
|ol (org)     |soft     |Org link support via `ol-cid.el` (opt-in load)     |
|embark       |soft     |Embark actions via `embark-cid.el` (opt-in load)   |

## Architecture

### `cid-mode.el` (~917 lines)

The mode is organized into these sections:

1. **Customization** — `defgroup cid`, `cid-gateway-url`,
   `cid-hex-bytes-per-line`, faces (`cid-header-face`,
   `cid-section-face`, `cid-field-face`)
2. **Constants** — Multibase, multicodec, and multihash tables
   (canonical names from the `go-multicodec` / `go-multibase` tables
   vendored in the IPFS Kubo source)
3. **Rx patterns** — `cid-char`, `cid-v0` (compiled
   `rx-define` patterns for CID detection; avoids inline regex strings
   in `string-match-p`)
4. **Encoding decoders** — base58btc, base32 (lower/upper/nopad), base16
5. **Encoding encoders** — base58btc, base32 (for conversion display)
6. **Varint decoder** — unsigned LEB128 used by CID framing
7. **Lookup helpers & conversion** — codec name/description,
   multihash name/size, multibase name, `cid--cidv0-to-v1`,
   `cid--cidv1-to-v0`
8. **CID parsing** — `cid-info` struct, `cid--decode-base`,
   `cid--detect-prefix`, `cid--parse-v0`, `cid--parse-v1`
9. **Display** — `cid-mode` derives from `magit-section-mode` and renders
   the decoded CID as a hierarchy of collapsible `magit-section` groups.
   Sections (Identity, Multihash, Sizes, Raw Bytes, CIDv0 Equivalent) use
   `magit-insert-section` / `magit-insert-heading`; individual fields
   (CID, Version, Algorithm, etc.) are nested `cid-field` sections.
10. **Commands** — `cid-decode`, `cid-decode-at-point`, `cid-decode-from-raw`,
    `cid-revert`, `cid-copy-cid`, `cid-copy-field-value`, `cid-open-gateway`
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

### `embark-cid.el` (~89 lines)

Opt-in Embark module.  Registers `ipfs-cid` as a target type:

- **Target finder** (`embark-cid-target-at-point`) — delegates to
  `cid--bounds`, returns `(ipfs-cid CID START . END)`
- **Actions** — `RET` (decode in `cid-mode`), `w` (copy to kill ring),
  `b` (open on IPFS gateway)

Every entry point carries `;;;###autoload`: the three commands, the
target finder, and the registration form below it.  The autoloads file
therefore registers the finder and the keymap as soon as Embark loads,
and the first `embark-act' on a CID loads `embark-cid.el' on demand:

```elisp
;;;###autoload
(with-eval-after-load 'embark
  (add-hook 'embark-target-finders #'embark-cid-target-at-point)
  (add-to-list 'embark-keymap-alist '(ipfs-cid . embark-cid-map)))
```

`cid-tests.el` checks these cookies in `embark-cid-autoloads`.  Users
can also load the module by hand:

```elisp
(require 'embark-cid)
```

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
    → multihash + digest (hex + base32 + base58btc) + bits
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
# Nix (flake)
nix build                       # build
nix flake check                 # build + ERT suite
nix build .#screenshot          # regenerate README screenshot
nix build .#gitrepo             # bare .git dir holding the screenshot

# Without Nix
emacs -Q --batch -f batch-byte-compile cid-mode.el
emacs -Q --batch -L . -f batch-byte-compile ol-cid.el
emacs -Q --batch -L . -f batch-byte-compile embark-cid.el
```

Dev shell: `nix develop` (Emacs).

Flake outputs: `packages.cid-mode` (= `default`) is the `melpaBuild`
derivation defined inline in `flake.nix`;
its `checkPhase` runs the ERT suite.  `melpaBuild` puts its
`packageRequires` in `propagatedBuildInputs`, and the Emacs setup hook
adds only `share/emacs/site-lisp`, not the `elpa/<pkg>-<version>`
subdirectories.  So magit-section never reaches `load-path` by itself.
The build defaults `emacsPackages` to a wrapped Emacs,
`pkgs.emacsPackagesFor (emacs.pkgs.withPackages (_: [ magit-section ]))`,
which carries the dependency and its closure on the load path.  The
derivation wraps in `lib.makeOverridable`, so a consumer can swap the
Emacs or the package set:

```nix
inputs.emacs-ipfs-modes.packages.${system}.cid-mode.override {
  emacs = pkgs.emacs-nox;
}
```

`packages.screenshot` and
`packages.gitrepo` come from `nix/emacs-screenshot.nix`, which uses
`mkGitRepository` imported from the `nur-packages` flake input (not
vendored).

The version string comes from the flake source info.  The commit date
`YYYY-MM-DD` from `inputs.self.sourceInfo.lastModifiedDate` becomes
`0.1.0-unstable-YYYY-MM-DD`, and `postPatch` rewrites the
`;; Version:` header of all three libraries to match.  A plain path
import has no git metadata, so the date falls back to the epoch.

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
# Run the full test suite (66 tests):
emacs -Q --batch -L . -l cid-tests.el -f ert-run-tests-batch-and-exit

# Smoke test decode commands:
emacs -Q --batch -L . -l cid-mode.el \
  --eval '(cid-decode "QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco")' \
  --eval '(cid-decode "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi")' \
  --eval '(message "All decodes OK")'
```

### Test vectors

|Vector                                                       |Type |Description                             |
|-------------------------------------------------------------|-----|----------------------------------------|
|`QmbGtJg23skhvFmu9mJiePVByhfzu5rwo74MEkVDYAmF5T`             |CIDv0|Big Buck Bunny, sha2-256, dag-pb        |
|`bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi`|CIDv1|base32 lowercase nopad, sha2-256, dag-pb|

## Keybindings

### `cid-mode-map` (global)

|Key         |Command                                           |Description                                                   |
|------------|--------------------------------------------------|--------------------------------------------------------------|
|`TAB`       |`magit-section-toggle`                            |Toggle collapse on section at point                           |
|`S-TAB`     |`magit-section-cycle`                             |Collapse all sections at current level                        |
|`n`/`p`     |`magit-section-forward`/`backward`                |Navigate between sections                                     |
|`M-n`/`M-p` |`magit-section-forward-sibling`/`backward-sibling`|Navigate between siblings                                     |
|`^`         |`magit-section-up`                                |Go to parent section                                          |
|`1`..`4`    |`magit-section-show-level-{1..4}`                 |Show sections up to level N                                   |
|`M-1`..`M-4`|`magit-section-show-level-{1..4}-all`             |Show all sections up to level N                               |
|`g`         |`cid-revert`                                      |Re-render the CID buffer                                      |
|`w`         |`cid-copy-cid`                                    |Copy CID string to kill ring                                  |
|`b`         |`cid-open-gateway`                                |Open CID on IPFS gateway                                      |
|`q`         |`quit-window`                                     |Close the CID buffer (inherited from `magit-section-mode-map`)|

### Section-specific keymaps

These keymaps are auto-discovered by magit-section via the naming convention
`magit-<TYPE>-section-map` — no explicit registration needed.

**`magit-cid-field-section-map`** — active on individual field lines
(Algorithm, Digest Size, Digest (hex), etc.):

|Key  |Command               |Description                  |
|-----|----------------------|-----------------------------|
|`y`  |`cid-copy-field-value`|Copy field value to kill ring|
|`RET`|`cid-copy-field-value`|Copy field value to kill ring|

**`magit-cid-section-section-map`** — active on section headings
(Identity, Multihash, Sizes, etc.):

|Key  |Command               |Description                      |
|-----|----------------------|---------------------------------|
|`RET`|`magit-section-toggle`|Toggle collapse/expand of section|

### Embark keybindings (`embark-cid-map`)

|Key  |Command                  |Description                    |
|-----|-------------------------|-------------------------------|
|`RET`|`embark-cid-decode`      |Decode CID in `cid-mode` buffer|
|`w`  |`embark-cid-copy`        |Copy CID to kill ring          |
|`b`  |`embark-cid-open-gateway`|Open CID on IPFS gateway       |

## Conventions

### Package name and the entry library

The package name matches the library, the provided feature and the
major mode: `pname = "cid-mode"` in `flake.nix`, `cid-mode.el`
in the source.  `use-package SYMBOL` expands to `(require SYMBOL)`
and `:ensure t` looks up the package named by SYMBOL, so the three
names must agree.  Users configure the package through
`(use-package cid-mode ...)`, with `M-x customize-group cid` for the
options and faces.

The package ships one mode, so it takes the mode name.  Do not add a
suite entry such as `ipfs-modes` while `cid-mode` stays the only
mode: a package name that names a plan confuses the `use-package`
lookup and hides the mode.  If a second mode lands in this
repository, rename the package then and declare the old name with
`:old-names` in the MELPA recipe.

Every user-facing command keeps its `;;;###autoload` cookie, and
`cid-tests.el` checks them in `cid-autoloads`.  Add a new command
there when adding it to `cid-mode.el`.  The autoload file also
registers the `ipfs://`/`ipns://` handlers and defers the `ol-cid`
require, so an installed package needs no explicit require.

### `defvar-keymap` with `:parent`

Keymaps use `defvar-keymap` with explicit `:parent` to inherit from
standard mode maps.  `cid-mode-map` inherits from `magit-section-mode-map`,
which provides `TAB`/`S-TAB` for collapse/cycle, `n`/`p` for
navigation, `1`..`4` for show-level commands, `q` (`quit-window`)
and `g` (`revert-buffer`) for free:

```elisp
(defvar-keymap cid-mode-map
  :doc "Keymap for `cid-mode' buffers."
  :parent magit-section-mode-map
  "g" #'cid-revert
  "w" #'cid-copy-cid
  "b" #'cid-open-gateway)
```

### Section-specific keymaps via naming convention

Magit-section automatically discovers per-section-type keymaps.  When
creating a section via `(magit-insert-section (cid-field "Algorithm") ...)`,
if a variable named `magit-cid-field-section-map` exists and is bound,
it is used as the section's keymap:

```elisp
(defvar-keymap magit-cid-field-section-map
  :doc "Keymap for CID field sections (individual field lines)."
  "RET" #'cid-copy-field-value
  "y"   #'cid-copy-field-value)

(defvar-keymap magit-cid-section-section-map
  :doc "Keymap for CID section headings (Identity, Multihash, etc.)."
  "RET" #'magit-section-toggle)
```

No manual `define-key` / `make-sparse-keymap` calls.

### `require` order

Required built-in packages come first, alphabetically, followed by
`cl-lib` and `magit-section`:

```elisp
(require 'bookmark)
(require 'browse-url)
(require 'cl-lib)
(require 'magit-section)
(require 'rx)
(require 'thingatpt)
```

### Derive from `magit-section-mode`

`cid-mode` derives from `magit-section-mode` (which itself derives from
`special-mode`).  This gives read-only buffers, collapsible sections,
navigation (`magit-section-forward`/`magit-section-backward`), and
standard buffer conventions for free.

### `cid-info` struct

All parsed data lives in a `cl-defstruct` value.  The mode only stores
one buffer-local variable (`cid--info`), making `revert-buffer` trivial.

### Pure decoder functions

All decoding/parsing functions declare `(side-effect-free t)` where
applicable.  Decoders that depend only on their arguments and the
constant multibase/multicodec/multihash tables also declare `(pure t)`,
so the byte compiler can fold them:

```elisp
(declare (pure t) (side-effect-free t))
```

Only `cid--display` and the interactive commands have side effects.
Functions that read point or buffer text (`cid--bounds`,
`cid--thing-at-point`) stay `side-effect-free` at most, never pure.

### Graceful error handling

Invalid encodings, truncated data, and unknown codes all produce
structured error messages (warnings in the display), not runtime
errors.

### `cid-decode-at-point`

Uses `skip-chars-forward/backward` and `rx`-compiled patterns to find
CIDs in any buffer.  CIDv0 detection is strict (exactly 46 base58
chars starting with `Qm`); CIDv1 detects any word starting with a
known multibase prefix (>= 3 chars).  The `rx` patterns are defined
once at compile time with `rx-define` and referenced via
`(rx cid-v0)` etc., avoiding inline regex strings in
`string-match-p`.  Candidates are then validated by actually decoding
via `cid--valid-cid-string-p` (see below), so words that merely share
a multibase prefix (e.g. `crate`, `cafebabe`) are rejected.  Note
that base32 CIDs legitimately contain `l`, so no ambiguous-character
exclusion is applied.

### `cid-decode-from-raw`

`cid-decode-from-raw` takes a hex-encoded hash digest and constructs a CIDv1
with the `raw` codec (0x55) and base58btc multibase encoding (`z` prefix).

The multihash algorithm is auto-detected from the digest length:

|Hex chars|Bytes|Algorithm|Code|
|---------|-----|---------|----|
|40       |20   |sha1     |0x11|
|64       |32   |sha2-256 |0x12|

When called interactively (`M-x cid-decode-from-raw`), prompts for the hex
digest and displays the resulting CID in a `cid-mode` buffer (via
`cid-decode`).  When called non-interactively, returns the CIDv1 string.

All invalid inputs (empty string, odd-length hex, unsupported byte
count) produce a single `user-error` with the expected lengths.

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
`cid-mode.el` requires `browse-url` at load time, so the handlers
are registered directly at load (with `;;;###autoload` for the
autoloads file).

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

`declare-function` silences the byte-compiler only.  It has no runtime
effect and creates no autoload.  Use it only when the target function
carries its own `;;;###autoload` cookie in the package autoloads file,
as `cid-decode` does:

```elisp
(declare-function cid-decode "cid-mode")     ; ol-cid.el
(defvar cid--info)
```

When the target is a private function without an autoload cookie,
`declare-function` leaves a void function at runtime.  Load the
package instead.  `embark-cid.el` calls `cid--bounds`, which has no
autoload cookie, so it requires the package:

```elisp
(require 'cid-mode)
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

### CID detection validates by decoding

`cid--bounds` finds word boundaries with `skip-chars-forward/backward`
and `rx`-compiled patterns, then validates the candidate with
`cid--valid-cid-string-p`: the word must fully decode to a CIDv0
multihash or a CIDv1 version/codec/multihash framing **without parse
errors**.  This rejects prose words that merely share a multibase
prefix (e.g. `crate` is base32pad-prefixed but decodes to bytes that
do not form a valid CID).  Base32 CIDs legitimately contain `l`, so
no ambiguous-character exclusion is applied.

### Display rendering

CID display uses `magit-insert-section` and `magit-insert-heading` to
build a hierarchy of collapsible sections.  The root is a `cid-root`
section; each data group (Identity, Multihash, etc.) is a `cid-section`;
each field label is a `cid-field` leaf.

The rendering is driven by the customizable `cid-sections-hook`:

```elisp
(defcustom cid-sections-hook
  '(cid-insert-header-section
    cid-insert-identity-section
    cid-insert-multihash-section
    cid-insert-sizes-section
    cid-insert-raw-bytes-section
    cid-insert-cidv0-section
    cid-insert-cidv1-section
    cid-insert-warnings-section)
  :type 'hook
  :group 'cid)
```

Users can add, remove, or reorder section inserters via
`M-x customize-variable RET cid-sections-hook`, or programmatically
with `add-hook` / `remove-hook`.  Each inserter is wrapped by
`magit-run-section-hook`, so an error in one doesn't break the whole
buffer.  Users can also disable individual inserters without removing
them from the hook using `magit-disabled-section-inserters`.

The three non-conditional inserters always run:

- `cid-insert-header-section` — CID string + version line + summary
- `cid-insert-identity-section` — CID, Version, Multibase, Codec
- `cid-insert-multihash-section` — Algorithm, Digest Size, digests (hex, base32, base58btc)
- `cid-insert-sizes-section` — CID string bytes, Binary bytes
- `cid-insert-raw-bytes-section` — hex dump

The conditional inserters only fire when applicable:

- `cid-insert-cidv0-section` — CIDv1 dag-pb sha2-256 → CIDv0 equivalent
- `cid-insert-cidv1-section` — CIDv0 → CIDv1 base32 equivalent
- `cid-insert-warnings-section` — parsing errors/warnings

Faces are defined as `defface` rather than inline `:inherit` props:

- `cid-header-face` — inherits `outline-1`; used for the CID string title
- `cid-section-face` — inherits `font-lock-keyword-face` + `bold`;
  used for section headings (Identity, Multihash, Sizes, etc.)
- `cid-field-face` — inherits `font-lock-type-face`; used for field
  labels (CID, Version, Multibase, etc.)

### `cid-decode-hook`

`cid-decode-hook` runs after a CID buffer is fully rendered, with
`cid--info` set.  Unlike `cid-mode-hook`, which fires during mode
initialization before `cid--info` is available, this hook lets you
modify the buffer based on the parsed CID data:

```elisp
(add-hook 'cid-decode-hook
  (lambda () (message "Decoded: %s" (cid-info-cid-string cid--info))))
```

### Buffer directory

CID buffers set `default-directory` to `temporary-file-directory`
instead of inheriting the user's current directory.
### Screenshot via Nix

`nix/emacs-screenshot.nix` provides a reproducible way to render CID decode
output as a PNG image, following the same pattern as `~/nixos.el` and
`~/crate.el`.  It receives the `cid-mode` derivation built in `flake.nix`
(passed in by the flake), launches an
Emacs frame under `xvfb-run` with the modus-operandi theme and Iosevka
font, decodes the Big Buck Bunny CID, makes the buffer the sole window,
sizes the frame to fit, and captures the frame with `x-export-frames`.

```
nix build .#screenshot --out-link /tmp/screenshot
```

Available outputs:
- `png` — light-theme PNG with imagemagick border + shadow + pngquant
- `svg` — dual-theme (light/dark) SVG via `svgDualTheme`
- `gitrepo` — SVG wrapped for git hosting
## TODO

- **`dag-mode`** — browse IPLD DAG nodes by following links in
  dag-pb/dag-cbor content
- **`ipfs-mode`** — interactive IPFS node control (peers, pinning,
  files)
- **`ipns-mode`** — browse IPNS records and keys

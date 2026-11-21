;;; cid-mode.el --- Decode and browse IPFS CIDs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, ipfs
;; Package-Requires: ((emacs "30.1") (magit-section "3.3.0"))
;; URL: https://github.com/nagy/emacs-ipfs-modes

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a major mode for decoding and browsing IPFS
;; Content Identifiers (CIDs), similar to the online tool at
;; <https://cid.ipfs.tech/>.
;;
;; CIDs are self-describing content-addressed identifiers used by IPFS
;; and related protocols.  This mode decodes a CID into its components:
;;
;;   - CID version (0 or 1)
;;   - Multibase encoding prefix (for CIDv1)
;;   - Multicodec (content type: dag-pb, dag-cbor, raw, etc.)
;;   - Multihash (hash algorithm + digest)
;;
;; The main entry point is `cid-decode', which prompts for a CID
;; string and displays the result in a `cid-mode' buffer.
;;
;; Usage:
;;
;;   M-x cid-decode         -- enter a CID string interactively
;;   M-x cid-decode-at-point -- decode a CID at point in any buffer

;;; Code:

(require 'bookmark)
(require 'browse-url)
(require 'cl-lib)
(require 'rx)
(require 'thingatpt)
(require 'magit-section)


;;; Customization

(defgroup cid nil
  "Decode and browse IPFS Content Identifiers."
  :group 'tools
  :prefix "cid-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/emacs-ipfs-modes"))

(defcustom cid-gateway-url
  (or (getenv "IPFS_GATEWAY") "https://ipfs.io")
  "IPFS gateway URL for resolving CIDs.
The default value comes from the IPFS_GATEWAY environment variable,
or from ipfs.io.  `cid-open-gateway' opens a CID at this gateway."
  :type 'string
  :group 'cid)

(defface cid-header-face
  '((t :inherit outline-1))
  "Face for the CID string header."
  :group 'cid)

(defface cid-section-face
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for section headings (Identity, Multihash, etc.)."
  :group 'cid)

(defface cid-field-face
  '((t :inherit font-lock-type-face))
  "Face for field labels (CID, Version, Multibase, etc.)."
  :group 'cid)

(defcustom cid-decode-hook nil
  "Hook run after a CID buffer is fully rendered.
The buffer is current and `cid--info' is set when this hook runs.
Use this to modify the buffer after `cid-decode' finishes.  Unlike
`cid-mode-hook', `cid--info' is available here.  A decode that
finds the same data already rendered skips the render and this
hook does not run again."
  :type 'hook
  :group 'cid)

(defcustom cid-hex-bytes-per-line 16
  "Number of hex bytes to show per line in the raw bytes dump."
  :type 'integer
  :group 'cid)


;;; Constants

(defconst cid--base58-alphabet
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  "Base58 bitcoin alphabet used by IPFS.")

(defconst cid--base32-lower-alphabet "abcdefghijklmnopqrstuvwxyz234567"
  "RFC 4648 base32 lowercase alphabet (no padding variant).")

(defconst cid--base32-upper-alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  "RFC 4648 base32 uppercase alphabet (no padding variant).")

(defconst cid--multibase-prefixes
  '(;; prefix . (name . decoder-symbol)
    ;; Names match the canonical go-multibase EncodingToStr table.
    (?f . ("base16" . lower-hex))
    (?F . ("base16upper" . upper-hex))
    (?b . ("base32" . lower))
    (?B . ("base32upper" . upper))
    (?c . ("base32pad" . lower-nopad))
    (?C . ("base32padupper" . upper-nopad))
    (?z . ("base58btc" . base58))
    (?Z . ("base58flickr" . base58))
    (?m . ("base64" . base64url))
    (?u . ("base64url" . base64url))
    (?M . ("base64pad" . base64url))
    (?U . ("base64urlpad" . base64url)))
  "Multibase prefixes and their encoding names.
Names match the canonical go-multibase table from the IPFS Kubo source.
The decoder-symbol indicates the internal decoder: lower-hex, upper-hex,
lower, upper, lower-nopad, upper-nopad, base58, or base64url.")

(defconst cid--codec-table
  '((#x55   . ("raw" . "raw binary"))
    (#x70   . ("dag-pb" . "MerkleDAG protobuf"))
    (#x71   . ("dag-cbor" . "MerkleDAG cbor"))
    (#x0129 . ("dag-json" . "MerkleDAG json"))
    (#x0120 . ("libp2p-key" . "Libp2p Public Key"))
    (#x01ce . ("json" . "JSON (UTF-8-encoded)"))
    (#x0202 . ("cbor" . "CBOR"))
    (#x01b0 . ("car" . nil))
    (#x01b1 . ("car-index-sorted" . nil))
    (#x01e0 . ("fil-commitment-unsealed" . nil))
    (#x01e1 . ("fil-commitment-sealed" . nil))
    (#x78   . ("git-raw" . "Raw Git object"))
    (#x00   . ("identity" . "raw binary")))
  "Known multicodec codes ((code . (name . description))).
Names and descriptions from the canonical go-multicodec table
in the IPFS Kubo source.")

(defconst cid--multihash-table
  '((#x00   . ("identity"    . 0))
    (#x11   . ("sha1"        . 20))
    (#x12   . ("sha2-256"    . 32))
    (#x13   . ("sha2-512"    . 64))
    (#x14   . ("sha3-512"    . 64))
    (#x15   . ("sha3-384"    . 48))
    (#x16   . ("sha3-256"    . 32))
    (#x17   . ("sha3-224"    . 28))
    (#x18   . ("shake-128"   . 32))
    (#x19   . ("shake-256"   . 64))
    (#x1a   . ("keccak-224"  . 28))
    (#x1b   . ("keccak-256"  . 32))
    (#x1c   . ("keccak-384"  . 48))
    (#x1d   . ("keccak-512"  . 64))
    (#x1e   . ("blake3"      . 32))
    (#xb220 . ("blake2b-256" . 32))
    (#xb240 . ("blake2b-512" . 64)))
  "Known multihash codes ((code . (name . digest-size))).
Codes and names from the canonical go-multicodec table in the
IPFS Kubo source.  Digest-size is the expected length in bytes,
or 0 for variable.")

;; `char' spells the same class as `any' but avoids a package-lint
;; false positive: package-lint reads the bare symbol `any' as the
;; Emacs 31 alias and demands a newer Emacs dependency.
(rx-define cid-char (char "A-Za-z0-9"))

(rx-define cid-v0
  (seq (repeat 46 cid-char)))

(rx-define cid-v0-strict
  (seq bos (eval cid--v0-prefix-chars) (one-or-more cid-char) eos))

(defvar cid--v0-prefix-chars "Qm"
  "Characters a CIDv0 must start with.
`rx-define' evaluates this at expansion time.")

(defconst cid--thing-char-class "A-Za-z0-9"
  "Character class for skipping to CID boundaries.
Used by `cid--bounds' with `skip-chars-forward' and `skip-chars-backward'.")


;;; Base58 decoding

(defun cid--base58-decode (str)
  "Decode base58btc STR to a byte vector.
Return nil if STR contains characters outside the base58 alphabet."
  (declare (side-effect-free t))
  (catch 'done
    (let ((alphabet cid--base58-alphabet)
          (leading-ones 0)
          (n 0))
      ;; Count leading '1's (which decode to leading zero bytes)
      (while (and (< leading-ones (length str))
                  (= (aref str leading-ones) ?1))
        (cl-incf leading-ones))
      ;; Decode the rest
      (let ((body (substring str leading-ones)))
        (when (string-empty-p body)
          (throw 'done (make-vector leading-ones 0)))
        (catch 'invalid
          (dotimes (i (length body))
            (let ((idx (cl-position (aref body i) alphabet :test #'eql)))
              (unless idx
                (throw 'invalid nil))
              (setq n (+ (* n 58) idx))))
          ;; Convert n to bytes (big-endian)
          (if (zerop n)
              (make-vector leading-ones 0)
            (let ((bytes nil))
              (while (> n 0)
                (push (logand n #xff) bytes)
                (setq n (ash n -8)))
              (vconcat (make-vector leading-ones 0) bytes))))))))


;;; Base32 decoding

(defun cid--base32-decode (str alphabet)
  "Decode base32 STR using ALPHABET.
Return a byte vector, or nil on invalid input."
  (declare (side-effect-free t))
  (let* ((clean (string-replace "=" "" str))
         (bits 0)
         (bit-count 0)
         (result nil))
    (catch 'invalid
      (dotimes (i (length clean))
        (let* ((char (aref clean i))
               (val (cl-position char alphabet :test #'eql)))
          (unless val
            (throw 'invalid nil))
          (setq bits (logior (ash bits 5) val)
                bit-count (+ bit-count 5))
          (when (>= bit-count 8)
            (push (logand (ash bits (- 8 bit-count)) #xff) result)
            (setq bit-count (- bit-count 8))))))
    (when result
      (vconcat (nreverse result)))))

(defun cid--base32-encode (bytes)
  "Encode BYTES to a base32 lowercase string (no padding)."
  (declare (side-effect-free t))
  (let* ((alphabet cid--base32-lower-alphabet)
         (result nil)
         (bits 0)
         (bit-count 0))
    (dotimes (i (length bytes))
      (setq bits (logior (ash bits 8) (aref bytes i))
            bit-count (+ bit-count 8))
      (while (>= bit-count 5)
        (push (aref alphabet (logand (ash bits (- 5 bit-count)) #x1f)) result)
        (setq bit-count (- bit-count 5))))
    (when (> bit-count 0)
      (push (aref alphabet (logand (ash bits (- 5 bit-count)) #x1f)) result))
    (concat (nreverse result))))

(defun cid--base58-encode (bytes)
  "Encode BYTES to a base58btc string."
  (declare (side-effect-free t))
  (let ((alphabet cid--base58-alphabet)
        (n 0))
    (dolist (b (append bytes nil))
      (setq n (+ (* n 256) b)))
    (if (zerop n)
        ""
      (let ((result nil))
        (while (> n 0)
          (push (aref alphabet (% n 58)) result)
          (setq n (/ n 58)))
        (concat result)))))

(defun cid--base16-decode (str)
  "Decode hex STR (lower or upper case) to a byte vector."
  (declare (side-effect-free t))
  (let ((len (length str))
        (result nil))
    (when (cl-evenp len)
      (dotimes (i (/ len 2))
        (push (string-to-number (substring str (* i 2) (+ (* i 2) 2)) 16)
              result))
      (vconcat (nreverse result)))))


;;; Varint decoding

(defun cid--decode-varint (v pos)
  "Decode an unsigned varint from vector V starting at POS.
Return (VALUE . NEW-POS) or nil if there are not enough bytes."
  (declare (side-effect-free t))
  (let ((value 0)
        (shift 0)
        (i pos))
    (catch 'done
      (while (and i (< i (length v)))
        (let ((b (aref v i)))
          (setq value (logior value (ash (logand b #x7f) shift))
                shift (+ shift 7))
          (cl-incf i)
          (when (zerop (logand b #x80))
            (throw 'done (cons value i)))))
      nil)))  ; incomplete varint


;;; Multicodec / multihash helpers

(defun cid--lookup-codec (code)
  "Return the name of multicodec CODE, or a hex string if unknown."
  (declare (side-effect-free t))
  (let ((entry (assq code cid--codec-table)))
    (if entry
        (cadr entry)
      (format "0x%x (unknown)" code))))

(defun cid--codec-description (code)
  "Return the description of multicodec CODE, or nil."
  (declare (side-effect-free t))
  (cddr (assq code cid--codec-table)))

(defun cid--lookup-multihash (code)
  "Return (NAME . EXPECTED-SIZE) for multihash CODE, or nil if unknown."
  (declare (side-effect-free t))
  (cdr (assq code cid--multihash-table)))

(defun cid--multibase-name (prefix)
  "Return the name of the multibase encoding for PREFIX character."
  (declare (side-effect-free t))
  (cadr (assq prefix cid--multibase-prefixes)))

(defun cid--encode-hex (bytes)
  "Return lowercase hex string for BYTES (vector or list)."
  (declare (side-effect-free t))
  (mapconcat (lambda (b) (format "%02x" b)) (append bytes nil) ""))

(defun cid--cidv1-to-v0 (info)
  "Return the CIDv0 string equivalent of a dag-pb sha2-256 CIDv1 INFO, or nil.
CIDv0 is only valid for dag-pb + sha2-256 CIDs."
  (declare (side-effect-free t))
  (when (and (= (cid-info-version info) 1)
             (= (cid-info-codec-code info) #x70)   ; dag-pb
             (= (cid-info-multihash-code info) #x12) ; sha2-256
             (cid-info-digest info))
    (cid--base58-encode (vconcat [ #x12 #x20 ] (cid-info-digest info)))))

(defun cid--cidv0-to-v1 (info)
  "Return the CIDv1 base32 string equivalent of a CIDv0 INFO.
CIDv0 is always dag-pb + sha2-256, so the conversion is unambiguous."
  (declare (side-effect-free t))
  (when (= (cid-info-version info) 0)
    (let* ((raw (cid-info-raw-bytes info))
           (v1-raw (vconcat [ #x01 #x70 ] raw)))
      (concat "b" (cid--base32-encode v1-raw)))))


;;; CID info struct

(cl-defstruct (cid-info
               (:constructor cid-info--create)
               (:conc-name cid-info-)
               (:type vector)
               (:named))
  cid-string        ;; the input string
  version           ;; 0 or 1
  multibase         ;; name of the multibase encoding
  codec             ;; name of the multicodec
  codec-code        ;; numeric codec code
  multihash-name    ;; hash algorithm name
  multihash-code    ;; numeric multihash code
  digest-size       ;; expected digest length in bytes
  digest            ;; digest bytes (vector)
  raw-bytes         ;; full decoded bytes (vector)
  errors)           ;; list of warning/error strings


;;; CID decoding and parsing

(defun cid--valid-cid-string-p (str)
  "Return non-nil if STR is a structurally valid CID.
Cheap lexical checks run first (v0: Qm + 46 base58 chars; v1: known
multibase prefix, >= 3 chars), then a full decode: CIDv0 strings
decode as base58btc and must parse as a multihash; CIDv1 strings
must decode to a version/codec/multihash framing.  The check
accepts a candidate only if it parses without errors, so it rejects
a word that merely shares a multibase prefix but does not decode
cleanly (for example \"crate\" or \"cafebabe\").  Note that base32
CIDs legitimately contain `l`, so no ambiguous-character exclusion
applies."
  (declare (side-effect-free t))
  (cond
   ;; CIDv0: exactly 46 base58 chars starting with Qm
   ((and (string-prefix-p cid--v0-prefix-chars str)
         (string-match-p (rx cid-v0) str))
    (when-let* ((raw (cid--base58-decode str))
                (info (cid--parse-v0 str raw)))
      (null (cid-info-errors info))))
   ;; CIDv1: known multibase prefix, >= 3 chars, and must decode cleanly.
   ((and (>= (length str) 3)
         (assq (aref str 0) cid--multibase-prefixes)
         (string-match-p (rx (seq bos (one-or-more cid-char) eos)) str))
    (when-let* ((raw (cid--decode-base str (aref str 0)))
                (info (cid--parse-v1 str (aref str 0) raw)))
      (null (cid-info-errors info))))
   (t nil)))

(defun cid--decode-base (str prefix)
  "Decode STR with multibase PREFIX character.
Return decoded byte vector, or nil on failure."
  (declare (side-effect-free t))
  (cond
   ((null prefix)
    (cid--base58-decode str))
   ((eq prefix ?z)
    (cid--base58-decode (substring str 1)))
   ((memq prefix '(?c ?b))
    (cid--base32-decode (substring str 1) cid--base32-lower-alphabet))
   ((memq prefix '(?C ?B))
    (cid--base32-decode (substring str 1) cid--base32-upper-alphabet))
   ((memq prefix '(?f ?F))
    (cid--base16-decode (substring str 1)))
   (t nil)))

(defun cid--detect-prefix (str)
  "Detect the multibase prefix of CID string STR.
Return the prefix character for CIDv1, or nil for CIDv0.
Return `unknown-prefix' for unrecognized first characters."
  (declare (side-effect-free t))
  (cond
   ;; CIDv0: starts with Qm, base58btc, 46 chars
   ((and (= (length str) 46)
         (string-match-p "\\`Qm[a-km-zA-HJ-NP-Z1-9]+\\'" str))
    nil)
   ;; CIDv1: first char is the multibase prefix
   ((assq (aref str 0) cid--multibase-prefixes)
    (aref str 0))
   (t 'unknown-prefix)))

(defun cid--parse-v0 (str raw-bytes)
  "Parse CIDv0 string STR from RAW-BYTES (decoded base58btc).
Return a `cid-info' struct, or nil if invalid."
  (declare (pure t) (side-effect-free t))
  (let ((errors nil))
    ;; CIDv0: the raw bytes are just the multihash itself.
    ;; Implicit: version=0, codec=dag-pb (0x70).
    (when-let* ((mh (cid--decode-varint raw-bytes 0)))
      (let* ((hash-code (car mh))
             (pos (cdr mh))
             (ds (cid--decode-varint raw-bytes pos))
             (mh-info (cid--lookup-multihash hash-code))
             (expected-size (if mh-info (cdr mh-info) 0))
             (digest-size (if ds (car ds) 0))
             (digest-start (if ds (cdr ds) (length raw-bytes)))
             (digest (and ds
                          (>= (length raw-bytes) (+ digest-start digest-size))
                          (cl-subseq raw-bytes digest-start
                                     (+ digest-start digest-size)))))
        (when (and (> expected-size 0)
                   (not (= digest-size expected-size)))
          (push (format "Multihash digest size mismatch: expected %d, got %d"
                        expected-size digest-size)
                errors))
        (cid-info--create
         :cid-string str
         :version 0
         :multibase "base58btc"
         :codec "dag-pb"
         :codec-code #x70
         :multihash-name (if mh-info (car mh-info)
                           (format "0x%x (unknown)" hash-code))
         :multihash-code hash-code
         :digest-size digest-size
         :digest digest
         :raw-bytes raw-bytes
         :errors errors)))))

(defun cid--parse-v1 (str prefix raw-bytes)
  "Parse CIDv1 string STR with multibase PREFIX from RAW-BYTES.
Return a `cid-info' struct, or nil if invalid."
  (declare (pure t) (side-effect-free t))
  (let ((errors nil))
    ;; CIDv1: [version-varint] [codec-varint] [multihash-varint digest...]
    (when-let* ((v (cid--decode-varint raw-bytes 0)))
      (let ((ver (car v))
            (pos (cdr v)))
        (unless (= ver 1)
          (push (format "Expected CID version 1, got %d" ver) errors))
        (when-let* ((c (cid--decode-varint raw-bytes pos)))
          (let* ((codec-code (car c))
                 (codec-name (cid--lookup-codec codec-code))
                 (pos2 (cdr c)))
            (unless (assq codec-code cid--codec-table)
              (push (format "Unknown codec 0x%x" codec-code) errors))
            (when-let* ((mh (cid--decode-varint raw-bytes pos2)))
              (let* ((hash-code (car mh))
                     (pos3 (cdr mh))
                     (ds (cid--decode-varint raw-bytes pos3))
                     (mh-info (cid--lookup-multihash hash-code))
                     (expected-size (if mh-info (cdr mh-info) 0))
                     (digest-size (if ds (car ds) 0))
                     (digest-start (if ds (cdr ds) (length raw-bytes)))
                     (digest (and ds
                                  (>= (length raw-bytes)
                                      (+ digest-start digest-size))
                                  (cl-subseq raw-bytes digest-start
                                             (+ digest-start digest-size)))))
                (when (and (> expected-size 0)
                           (not (= digest-size expected-size)))
                  (push (format "Multihash digest size mismatch: \
expected %d, got %d"
                                expected-size digest-size)
                        errors))
                (cid-info--create
                 :cid-string str
                 :version ver
                 :multibase (cid--multibase-name prefix)
                 :codec codec-name
                 :codec-code codec-code
                 :multihash-name (if mh-info (car mh-info)
                                   (format "0x%x (unknown)" hash-code))
                 :multihash-code hash-code
                 :digest-size digest-size
                 :digest digest
                 :raw-bytes raw-bytes
                 :errors errors)))))))))

;;;###autoload
(defun cid-decode (cid-string)
  "Decode CID-STRING and display its components in a `cid-mode' buffer."
  (interactive "sCID: ")
  (let ((str (string-trim cid-string)))
    (when (string-empty-p str)
      (user-error "CID string must not be empty"))
    (let* ((prefix (cid--detect-prefix str))
           (info nil))
      (cond
       ((eq prefix 'unknown-prefix)
        (user-error "Unrecognized CID format: unknown multibase prefix `%c'"
                    (aref str 0)))
       ((null prefix)
        ;; CIDv0
        (let ((raw (cid--base58-decode str)))
          (unless raw
            (user-error "Invalid base58btc encoding"))
          (setq info (cid--parse-v0 str raw))
          (unless info
            (user-error "Invalid CIDv0: could not parse multihash"))))
       (t
        ;; CIDv1
        (let ((raw (cid--decode-base str prefix)))
          (unless raw
            (user-error "Invalid multibase encoding for prefix `%c'" prefix))
          (setq info (cid--parse-v1 str prefix raw))
          (unless info
            (user-error "Invalid CIDv1: could not parse structure")))))
      (cid--display info))))


;;; Display

(defvar-keymap magit-cid-field-section-map
  :doc "Keymap for CID field sections (individual field lines)."
  "RET" #'cid-copy-field-value
  "y"   #'cid-copy-field-value)

(defvar-keymap magit-cid-section-section-map
  :doc "Keymap for CID section headings (Identity, Multihash, etc.)."
  "RET" #'magit-section-toggle)

(defvar-keymap cid-mode-map
  :doc "Keymap for `cid-mode' buffers."
  :parent magit-section-mode-map
  "g" #'cid-revert
  "w" #'cid-copy-cid
  "b" #'cid-open-gateway)

(defvar-local cid--info nil
  "The `cid-info' struct for the current buffer.")

(define-derived-mode cid-mode magit-section-mode "CID"
  "Major mode for displaying decoded IPFS Content Identifiers.

To decode a CID, type \\[cid-decode].

\\{cid-mode-map}"
  :interactive nil
  (setq-local revert-buffer-function #'cid-revert)
  (setq-local bookmark-make-record-function #'cid--bookmark-make-record)
  (setq-local imenu-create-index-function #'cid--imenu-index)
  (setq-local list-buffers-directory nil)
  ;; A render inserts the whole tree once and then only reads it, and
  ;; no section opens a lazy body, so plain integers stay valid and a
  ;; large tree avoids the superlinear marker cost.  Never give a
  ;; section a lazy body (`magit-insert-section-body'): it signals
  ;; `markerp' here.  Never edit the buffer after a render: the
  ;; integers go stale.
  (setq-local magit-section-inhibit-markers t)
  ;; Headings carry their text verbatim and show no child counts, so
  ;; the count rewrite never fires and never moves recorded positions.
  (setq-local magit-section-show-child-count nil)
  ;; Keep the parent value of `truncate-lines'.  A CID and a hex
  ;; digest have no break points, so a wrapped value reads as two
  ;; values.  Spell the value out, so a change in the parent mode
  ;; cannot silently start wrapping.
  (setq-local truncate-lines t))

;;; Sections hook

(defcustom cid-sections-hook
  '(cid-insert-header-section
    cid-insert-identity-section
    cid-insert-multihash-section
    cid-insert-sizes-section
    cid-insert-raw-bytes-section
    cid-insert-cidv0-section
    cid-insert-cidv1-section
    cid-insert-warnings-section)
  "Hook run to insert sections into a `cid-mode' buffer.
Each function is called with no arguments; `cid--info' is
the buffer-local `cid-info' struct for the current CID.
Functions should insert their content at point using
`magit-insert-section' and `magit-insert-heading'.
An error in one function does not prevent others from
running (via `magit-run-section-hook')."
  :type 'hook
  :group 'cid)

;;; Section inserters

(defmacro cid--insert-section (title &rest body)
  "Insert a magit-section group with TITLE heading and BODY forms."
  (declare (indent 1))
  `(magit-insert-section (cid-section ,title)
     (magit-insert-heading
       (propertize (concat ,title "\n") 'face 'cid-section-face))
     ,@body
     (insert "\n")))

(defun cid-insert-header-section ()
  "Insert the CID string header and version line."
  (let ((info cid--info))
    (cid--insert-header (cid-info-cid-string info) (cid-info-version info))
    (insert "\n")
    (insert (propertize
             (format "%s - cidv%d - %s - (%s : %d : %s)"
                     (cid-info-multibase info)
                     (cid-info-version info)
                     (cid-info-codec info)
                     (cid-info-multihash-name info)
                     (* 8 (cid-info-digest-size info))
                     (if (cid-info-digest info)
                         (upcase (cid--encode-hex (cid-info-digest info)))
                       ""))
             'face '(:inherit shadow))
            "\n")
    (insert "\n")))

(defun cid-insert-identity-section ()
  "Insert the Identity section with CID, Version, Multibase, Codec."
  (let ((info cid--info))
    (cid--insert-section "Identity"
      (cid--insert-field "CID" (cid-info-cid-string info))
      (cid--insert-field "Version" (format "CIDv%d" (cid-info-version info)))
      (cid--insert-field "Multibase" (cid-info-multibase info))
      (cid--insert-field "Codec" (cid-info-codec info))
      (cid--insert-value (format "[0x%x]" (cid-info-codec-code info)))
      (when-let* ((desc (cid--codec-description (cid-info-codec-code info))))
        (cid--insert-value desc)))))

(defun cid-insert-multihash-section ()
  "Insert the Multihash section with Algorithm, Digest Size, digests."
  (let ((info cid--info))
    (cid--insert-section "Multihash"
      (cid--insert-field "Algorithm"
                         (concat (cid-info-multihash-name info)
                                 (format " [0x%x]" (cid-info-multihash-code info))))
      (cid--insert-field "Digest Size"
                         (format "%d bytes / %d bits"
                                 (cid-info-digest-size info)
                                 (* 8 (cid-info-digest-size info))))
      (when-let* ((digest (cid-info-digest info)))
        (cid--insert-field "Digest (hex)" (cid--encode-hex digest))
        (cid--insert-field "Digest (base32)" (cid--base32-encode digest))
        (cid--insert-field "Digest (base58btc)"
                           (cid--base58-encode digest))))))

(defun cid-insert-sizes-section ()
  "Insert the Sizes section."
  (let ((info cid--info))
    (cid--insert-section "Sizes"
      (cid--insert-field "CID string"
                         (format "%d bytes" (length (cid-info-cid-string info))))
      (cid--insert-field "Binary"
                         (format "%d bytes" (length (cid-info-raw-bytes info)))))))

(defun cid-insert-raw-bytes-section ()
  "Insert the Raw Bytes hex dump section."
  (let ((info cid--info))
    (cid--insert-section "Raw Bytes"
      (cid--insert-hex-dump (cid-info-raw-bytes info)))))

(defun cid-insert-cidv0-section ()
  "Insert CIDv0 Equivalent section, if applicable."
  (when-let* ((info cid--info)
              (v0 (cid--cidv1-to-v0 info)))
    (cid--insert-section "CIDv0 Equivalent"
      (cid--insert-field "CIDv0" v0))))

(defun cid-insert-cidv1-section ()
  "Insert CIDv1 Equivalent section, if applicable."
  (when-let* ((info cid--info)
              (v1 (cid--cidv0-to-v1 info)))
    (cid--insert-section "CIDv1 Equivalent"
      (cid--insert-field "CIDv1 (base32)" v1))))

(defun cid-insert-warnings-section ()
  "Insert the Warnings section, if there are any."
  (when-let* ((info cid--info)
              (errors (cid-info-errors info))
              (errors (reverse errors)))
    (cid--insert-section "Warnings"
      (dolist (err errors)
        (insert "  " (propertize err 'face 'warning) "\n")))))

(defun cid-copy-field-value ()
  "Copy the value of the current field to the kill ring.
Works on `cid-field' sections (field lines like Algorithm, Digest Size, etc.)."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'cid-field))
      (user-error "No field at point"))
    ;; The buffer text is: "%-18s LABEL VALUE".  The 19 below couples
    ;; to the padding in `cid--insert-field': change the two together.
    (save-excursion
      (goto-char (oref section start))
      (forward-char 19)
      (let ((value (buffer-substring-no-properties (point) (line-end-position))))
        (kill-new value)
        (message "Copied: %s" value)))))



(defvar-local cid--rendered nil
  "Data of the last render of the current buffer.
`cid--display' compares it with the data of the next display call
and skips the render when the two match.")

(defmacro cid--unless-rendered (key &rest body)
  "Unless KEY equals the data of the last render, evaluate BODY.
KEY holds the decoded data and the section hook, so a changed CID
or a changed hook renders and an identical one keeps the buffer,
its point and its folds."
  (declare (indent 1))
  `(unless (equal ,key cid--rendered)
     ,@body
     (setq-local cid--rendered ,key)))

(defun cid--render ()
  "Render the current buffer as a tree of CID sections.
The tree comes from `cid-sections-hook'.  Point and the folds
survive the render through the section idents."
  (let ((record (cid--point-record)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      ;; The root value names the buffer kind, so a second mode must
      ;; not reuse `cid'.  Keep a count or a size in the heading text
      ;; and never in a section value: the value is the ident that
      ;; carries the fold and the point record, and a changing ident
      ;; loses both.
      (magit-insert-section (cid-root 'cid)
        (magit-run-section-hook 'cid-sections-hook))
      (set-buffer-modified-p nil))
    ;; Show the root to apply the folds cached in
    ;; `magit-section-visibility-cache'.  Do it with caching off, so
    ;; the cache keeps only the sections that a reader folded.
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (cid--restore-record record)))

(defun cid--point-record (&optional position)
  "Return a record of the line at POSITION, or nil.
The record holds the section, the line offset from the section
start and the column, which `cid--restore-record' replays after a
render."
  (let ((position (or position (point))))
    ;; Measure the offset with `line-number-at-pos' differences:
    ;; `count-lines' answers 1 for a region inside one line.
    (when-let* ((section (magit-section-at position)))
      (list :section section
            :line (- (line-number-at-pos position)
                     (line-number-at-pos (oref section start)))
            :column (- position
                       (save-excursion
                         (goto-char position)
                         (line-beginning-position)))))))

(defun cid--restore-record (record)
  "Move point to the line that RECORD names.
Land at `point-min' when the recorded section is gone from the
current tree."
  (goto-char (or (when-let* ((section (plist-get record :section)))
                   (save-excursion
                     (when (magit-section-goto-successor
                            section
                            (plist-get record :line)
                            (plist-get record :column))
                       (point))))
                 (point-min))))

(defun cid--imenu-index ()
  "Return an imenu index of the sections of the current CID buffer.
The index holds the section headings and the field labels, in
buffer order."
  (let (index)
    (magit-map-sections
     (lambda (section)
       (when (memq (oref section type) '(cid-section cid-field))
         (push (cons (oref section value) (oref section start)) index))))
    ;; `magit-map-sections' yields depth first and ends with the root,
    ;; so sort by start position to get buffer order.
    (sort index (lambda (a b) (< (cdr a) (cdr b))))))

(defun cid--display (info)
  "Display decoded CID INFO in a `cid-mode' buffer."
  (let ((buf (get-buffer-create
              (format "CID: %s" (cid-info-cid-string info)))))
    (with-current-buffer buf
      (cid--unless-rendered (list info cid-sections-hook)
        (cid-mode)
        (setq-local default-directory temporary-file-directory)
        (setq cid--info info)
        (cid--render)
        ;; Inside `cid--unless-rendered', so a decode that skips the
        ;; render leaves the hook unrun.  A decoration that must
        ;; survive a revisit belongs in `cid-mode-hook' or in the
        ;; buffer setup.
        (run-hooks 'cid-decode-hook)))
    (pop-to-buffer buf)))

(defun cid--insert-header (cid-string version)
  "Insert a formatted header for CID-STRING and VERSION."
  (insert (propertize (truncate-string-to-width cid-string 72 nil nil t)
                      'face 'cid-header-face)
          "\n")
  (insert (propertize (format "CIDv%d" version)
                      'face '(:inherit shadow :height 0.9))
          "\n"))
(defun cid--insert-field (label value)
  "Insert a magit-section for a single field with LABEL and VALUE."
  (magit-insert-section (cid-field label)
    (insert (propertize (format "%-18s " label) 'face 'cid-field-face)
            (propertize value 'face 'font-lock-string-face)
            "\n")))

(defun cid--insert-value (value)
  "Insert a continuation VALUE indented to align with fields."
  (insert (make-string 19 ?\s)
          (propertize value 'face 'font-lock-builtin-face)
          "\n"))

(defun cid--insert-hex-dump (bytes)
  "Insert a formatted hex dump of BYTES."
  (let ((len (length bytes))
        (col-width cid-hex-bytes-per-line))
    (insert (propertize (format "  Hex dump (%d bytes)" len)
                        'face 'font-lock-comment-face)
            "\n")
    (dotimes (offset len)
      (when (zerop (mod offset col-width))
        (when (> offset 0) (insert "\n"))
        (insert "    "))
      (insert (format "%02x" (aref bytes offset))))
    (insert "\n")))


;;; Commands

(defun cid-revert (&rest _ignored)
  "Refresh the current CID buffer."
  (interactive)
  (unless cid--info
    (user-error "No CID info in this buffer"))
  (cid--display cid--info))

(defun cid-copy-cid ()
  "Copy the raw CID string to the kill ring."
  (interactive)
  (unless (and cid--info (cid-info-cid-string cid--info))
    (user-error "No CID in this buffer"))
  (kill-new (cid-info-cid-string cid--info))
  (message "Copied: %s" (cid-info-cid-string cid--info)))

(defun cid-open-gateway ()
  "Open the current CID on the configured IPFS gateway."
  (interactive)
  (unless (and cid--info (cid-info-cid-string cid--info))
    (user-error "No CID in this buffer"))
  (browse-url (format "%s/ipfs/%s" cid-gateway-url
                      (cid-info-cid-string cid--info))))

;;;###autoload
(defun cid-decode-from-raw (hex-digest)
  "Create a CIDv1 with raw codec from HEX-DIGEST (a hex-encoded hash).
When called interactively, prompt for the hex digest and display
the resulting CID in a `cid-mode' buffer.  When called
non-interactively, return the CIDv1 string.

The digest length selects the multihash algorithm:
  40 hex chars (20 bytes) → sha1
  64 hex chars (32 bytes) → sha2-256"
  (interactive "sHex-encoded digest: ")
  (let* ((hex (string-trim hex-digest))
         (digest (cid--base16-decode hex))
         (byte-len (and digest (length digest)))
         (hash-code
          (pcase byte-len
            (20 #x11)                      ; sha1
            (32 #x12)                      ; sha2-256
            (_
             (user-error
              "Unsupported digest length %d bytes (expected 20=sha1, 32=sha2-256)"
              (or byte-len 0)))))         ;; CIDv1 binary: version=1, codec=raw, multihash
         (binary (vconcat (vector #x01 #x55 hash-code byte-len) digest))
         (cid-str (concat "z" (cid--base58-encode binary))))
    (if (called-interactively-p 'any)
        (cid-decode cid-str)
      cid-str)))

;;;###autoload
(defun cid-decode-at-point ()
  "Decode the CID at point in the current buffer."
  (interactive)
  (let ((bounds (cid--bounds)))
    (unless bounds
      (user-error "No CID found at point"))
    (cid-decode (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(defun cid--bounds ()
  "Return bounds of a CID around point, or nil.
Handles both CIDv0 (Qm...) and CIDv1 (multibase prefix)."
  (let ((p (point)))
    (save-excursion
      (skip-chars-backward cid--thing-char-class)
      (let ((start (point))
            end)
        (goto-char p)
        (skip-chars-forward cid--thing-char-class)
        (setq end (point))
        (when (> end start)
          (let ((word (buffer-substring-no-properties start end)))
            (when (cid--valid-cid-string-p word)
              (cons start end))))))))

(defun cid--thing-at-point ()
  "Return the CID string at point, or nil.
For `thing-at-point' integration."
  (when-let* ((bounds (cid--bounds)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

;; The `cid' thing type works in any buffer, not only in `cid-mode'
;; buffers, so `thing-at-point' and Embark reach a CID in a log line or
;; a mail message.
(put 'cid 'bounds-of-thing-at-point #'cid--bounds)
(put 'cid 'thing-at-point #'cid--thing-at-point)


;;; Bookmarks

;;;###autoload
(defun cid-bookmark-jump (bmk)
  "Jump to CID bookmark BMK."
  (let ((cid (bookmark-prop-get bmk 'cid)))
    (unless cid
      (user-error "Bookmark has no CID"))
    (cid-decode cid)))
(put 'cid-bookmark-jump 'bookmark-handler-type "CID")

(defun cid--bookmark-make-record ()
  "Create a bookmark record for the current CID buffer."
  (when (and cid--info (cid-info-cid-string cid--info))
    `(,(format "CID: %s" (cid-info-cid-string cid--info))
      (handler . cid-bookmark-jump)
      (cid . ,(cid-info-cid-string cid--info))
      (location . ,(format "CID `%s'" (cid-info-cid-string cid--info))))))

;;; Org integration
;; Opt-in: users or package managers must install ol-cid.el alongside
;; cid-mode.el.  This deferred require loads the Org link support when
;; Org is loaded.
(with-eval-after-load 'org
  (require 'ol-cid nil t))  ; nil means no error if ol-cid is missing

;;; URL scheme handlers (ipfs:// and ipns://)

(defun cid--browse-ipfs (url &rest _)
  "Browse an ipfs:// or ipns:// URL.
Extract the CID or IPNS name from URL and open it on
the configured IPFS gateway."
  (string-match "\\`\\(ipfs\\|ipns\\)://\\(.+\\)" url)
  (let ((scheme (match-string 1 url))
        (content (match-string 2 url)))
    (browse-url (format "%s/%s/%s" cid-gateway-url scheme content))))

;;;###autoload
;; browse-url is required above, so the handlers can be registered
;; directly at load time (no with-eval-after-load needed).  They go into
;; `browse-url-default-handlers', not into the user-reserved
;; `browse-url-handlers', so a user entry wins and stays intact.
(add-to-list 'browse-url-default-handlers
             (cons "\\`ipfs://" #'cid--browse-ipfs))
(add-to-list 'browse-url-default-handlers
             (cons "\\`ipns://" #'cid--browse-ipfs))

(provide 'cid-mode)
;;; cid-mode.el ends here

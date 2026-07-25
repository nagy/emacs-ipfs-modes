;;; cid-mode.el --- Decode and browse IPFS Content Identifiers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, ipfs
;; Package-Requires: ((emacs "30.1"))
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
(require 'cl-lib)


;;; Customization

(defgroup cid nil
  "Decode and browse IPFS Content Identifiers."
  :group 'tools
  :prefix "cid-"
  :link '(url-link :tag "Repository" "https://github.com/nagy/emacs-ipfs-modes"))

(defcustom cid-gateway-url "https://ipfs.io"
  "IPFS gateway URL for resolving CIDs.
Used by `cid-gateway-url' command to open a CID in a browser."
  :type 'string
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
    (?f . ("base16" . lower-hex))
    (?F . ("base16" . upper-hex))
    (?b . ("base32" . lower))
    (?B . ("base32" . upper))
    (?c . ("base32" . lower-nopad))
    (?C . ("base32" . upper-nopad))
    (?z . ("base58btc" . base58))
    (?m . ("base64url" . base64url))
    (?u . ("base64" . base64))
    (?U . ("base64pad" . base64)))
  "Multibase prefixes and their encoding names.")

(defconst cid--codec-table
  '((#x55   . "raw")
    (#x70   . "dag-pb")
    (#x71   . "dag-cbor")
    (#x0129 . "dag-json")
    (#x0120 . "libp2p-key")
    (#x01ce . "json")
    (#x0202 . "cbor")
    (#x01b0 . "car")
    (#x01b1 . "car-index-sorted")
    (#x01e0 . "fil-commitment-unsealed")
    (#x01e1 . "fil-commitment-sealed")
    (#x03   . "git-raw")
    (#x00   . "identity"))
  "Known multicodec codes (code . name).")

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
    (#x1a   . ("keccak-512"  . 64))
    (#x1b   . ("keccak-256"  . 32))
    (#xb201 . ("blake2b-256" . 32))
    (#xb202 . ("blake2b-512" . 64))
    (#xb220 . ("blake3-256"  . 32))
    (#xb222 . ("blake3-512"  . 64)))
  "Known multihash codes ((code . (name . digest-size))).
Digest-size is the expected length in bytes, or 0 for variable.")


;;; Base58 decoding

(defun cid--base58-decode (str)
  "Decode base58btc STR to a byte vector.
Returns nil if STR contains characters outside the base58 alphabet."
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
Returns a byte vector, or nil on invalid input."
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

(defun cid--base16-decode (str)
  "Decode hex STR (lower or upper case) to a byte vector."
  (declare (side-effect-free t))
  (let ((len (length str))
        (result nil))
    (when (evenp len)
      (dotimes (i (/ len 2))
        (push (string-to-number (substring str (* i 2) (+ (* i 2) 2)) 16)
              result))
      (vconcat (nreverse result)))))


;;; Varint decoding

(defun cid--decode-varint (v pos)
  "Decode an unsigned varint from vector V starting at POS.
Returns (VALUE . NEW-POS) or nil if there aren't enough bytes."
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
  (or (cdr (assq code cid--codec-table))
      (format "0x%x (unknown)" code)))

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

(defun cid--decode-base (str prefix)
  "Decode STR with multibase PREFIX character.
Returns decoded byte vector, or nil on failure."
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
Returns the prefix character for CIDv1, or nil for CIDv0.
Returns `unknown-prefix' for unrecognized first characters."
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
  "Parse a CIDv0 from RAW-BYTES (decoded base58btc).
Returns a `cid-info' struct, or nil if invalid."
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
  "Parse a CIDv1 from RAW-BYTES with multibase PREFIX.
Returns a `cid-info' struct, or nil if invalid."
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

(defvar-keymap cid-mode-map
  :doc "Keymap for `cid-mode' buffers."
  :parent special-mode-map
  "g" #'cid-revert
  "w" #'cid-copy-cid
  "b" #'cid-open-gateway)

(defvar-local cid--info nil
  "The `cid-info' struct for the current buffer.")

(define-derived-mode cid-mode special-mode "CID"
  "Major mode for displaying decoded IPFS Content Identifiers.

\\{cid-mode-map}
Use `M-x cid-decode' to decode a CID."
  (setq-local revert-buffer-function #'cid-revert)
  (setq-local bookmark-make-record-function #'cid--bookmark-make-record))

(defun cid--display (info)
  "Display decoded CID INFO in a `cid-mode' buffer."
  (let ((buf (get-buffer-create
              (format "*CID: %s*" (cid-info-cid-string info))))
        (inhibit-read-only t))
    (with-current-buffer buf
      (erase-buffer)
      (cid-mode)
      (setq cid--info info)

      (cid--insert-header (cid-info-cid-string info) (cid-info-version info))
      (insert "\n")

      ;; General info section
      (cid--insert-section "Identity")
      (cid--insert-field "CID" (cid-info-cid-string info))
      (cid--insert-field "Version" (format "CIDv%d" (cid-info-version info)))
      (cid--insert-field "Multibase" (cid-info-multibase info))
      (cid--insert-field "Codec" (cid-info-codec info))
      (cid--insert-value (format "[0x%x]" (cid-info-codec-code info)))
      (insert "\n")

      ;; Multihash section
      (cid--insert-section "Multihash")
      (cid--insert-field "Algorithm"
                         (concat (cid-info-multihash-name info)
                                 (format " [0x%x]"
                                         (cid-info-multihash-code info))))
      (cid--insert-field "Digest Size"
                         (format "%d bytes" (cid-info-digest-size info)))
      (when-let* ((digest (cid-info-digest info)))
        (cid--insert-field "Digest (hex)" (cid--encode-hex digest)))
      (insert "\n")

      ;; Raw bytes section
      (cid--insert-section "Raw Bytes")
      (cid--insert-field "Total size"
                         (format "%d bytes" (length (cid-info-raw-bytes info))))
      (cid--insert-hex-dump (cid-info-raw-bytes info))

      ;; Warnings
      (when-let* ((errors (cid-info-errors info))
                  (errors (reverse errors)))
        (insert "\n")
        (cid--insert-section "Warnings")
        (dolist (err errors)
          (insert "  " (propertize err 'face 'warning) "\n")))

      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (pop-to-buffer buf)))

(defun cid--insert-header (cid-string version)
  "Insert a formatted header for CID-STRING and VERSION."
  (insert (propertize (truncate-string-to-width cid-string 72 nil nil t)
                      'face '(:inherit bold :height 1.2))
          "\n")
  (insert (propertize (format "CIDv%d" version)
                      'face '(:inherit shadow :height 0.9))
          "\n"))

(defun cid--insert-section (title)
  "Insert a section heading for TITLE."
  (insert (propertize (concat "╔═ " title "\n")
                      'face '(:inherit font-lock-keyword-face :weight bold))))

(defun cid--insert-field (label value)
  "Insert LABEL and VALUE on a line."
  (insert (propertize (format "  %-14s " label) 'face 'font-lock-type-face)
          (propertize value 'face 'font-lock-string-face)
          "\n"))

(defun cid--insert-value (value)
  "Insert a continuation VALUE indented to align with fields."
  (insert (make-string 18 ?\s)
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
      (skip-chars-backward "A-Za-z0-9")
      (let ((start (point))
            end)
        (goto-char p)
        (skip-chars-forward "A-Za-z0-9")
        (setq end (point))
        (when (> end start)
          (let ((word (buffer-substring-no-properties start end)))
            (when (or
                   ;; CIDv0: exactly 46 chars, starts with Qm
                   (and (= (length word) 46)
                        (string-prefix-p "Qm" word)
                        (string-match-p "\\`[A-Za-z0-9]+\\'" word))
                   ;; CIDv1: starts with known multibase prefix
                   (and (>= (length word) 3)
                        (assq (aref word 0) cid--multibase-prefixes)
                        (string-match-p "\\`[A-Za-z0-9]+\\'" word)
                        (not (string-match-p "[0OIl]" word))))
              (cons start end))))))))


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

(provide 'cid-mode)
;;; cid-mode.el ends here

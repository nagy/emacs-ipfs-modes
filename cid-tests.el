;;; cid-tests.el --- Tests for cid-mode -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

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

;; To run these tests:
;;
;;   (require 'cid-mode)
;;   (require 'ert)
;;
;; Then: M-x ert RET cid

;;; Code:

(require 'cid-mode)
(require 'ert)
(require 'cl-lib)


;;; Known test vectors

;; CIDv0: Big Buck Bunny movie reference hash (sha2-256, dag-pb).
;; Raw bytes: the multihash itself — 0x12 0x20 followed by 32 bytes of digest.
(defconst cid-test--v0-str "QmbGtJg23skhvFmu9mJiePVByhfzu5rwo74MEkVDYAmF5T"
  "Known-good CIDv0 string (Big Buck Bunny).")

(defconst cid-test--v0-digest-hex
  "c030fad635ba4625a2ec6e8bbf81c495c474cc823640cc0182cc0311326061ca"
  "Expected sha2-256 digest for the Big Buck Bunny CID.")

;; CIDv1: dag-pb, sha2-256, base32 lowercase nopad.
(defconst cid-test--v1-str "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
  "Known-good CIDv1 string (base32 lowercase).")

(defconst cid-test--v1-digest-hex
  "c3c4733ec8affd06cf9e9ff50ffc6bcd2ec85a6170004bb709669c31de94391a"
  "Expected sha2-256 digest for the v1 test CID.")

(defconst cid-test--v1-raw-hex
  "01701220c3c4733ec8affd06cf9e9ff50ffc6bcd2ec85a6170004bb709669c31de94391a"
  "Expected raw bytes (version + codec + multihash) for the v1 test CID.")


;;; Helpers

(defun cid-test--hex-to-bytes (hex)
  "Convert HEX string to a byte vector."
  (declare (side-effect-free t))
  (let ((len (length hex))
        (result nil))
    (dotimes (i (/ len 2))
      (push (string-to-number (substring hex (* i 2) (+ (* i 2) 2)) 16)
            result))
    (vconcat (nreverse result))))


;;; Base58 decoding

(ert-deftest cid-base58-decode-v0 ()
  "Base58 decoding of a known CIDv0 yields expected bytes."
  (let ((bytes (cid--base58-decode cid-test--v0-str)))
    (should (vectorp bytes))
    (should (= (length bytes) 34))        ; 2-byte multihash header + 32-byte digest
    ;; First byte is the multihash algorithm (sha2-256 = 0x12).
    (should (= (aref bytes 0) #x12))
    ;; Second byte is the digest length (32).
    (should (= (aref bytes 1) #x20))
    ;; Last 32 bytes match the expected digest.
    (let ((digest-hex (cid--encode-hex (cl-subseq bytes 2 34))))
      (should (equal digest-hex cid-test--v0-digest-hex)))))

(ert-deftest cid-base58-decode-invalid-char ()
  "Base58 decoding returns nil for strings with invalid characters."
  (should-not (cid--base58-decode "Qm0OIl!@#$")))

(ert-deftest cid-base58-decode-leading-ones ()
  "Base58 decoding handles leading '1' characters correctly."
  (let ((bytes (cid--base58-decode "111")))
    (should (vectorp bytes))
    (should (= (length bytes) 3))
    (should (= (aref bytes 0) 0))
    (should (= (aref bytes 1) 0))
    (should (= (aref bytes 2) 0))))

(ert-deftest cid-base58-decode-empty-body ()
  "Base58 decoding of a string that is all '1's yields a zero vector."
  (let ((bytes (cid--base58-decode "11")))
    (should (vectorp bytes))
    (should (= (length bytes) 2))
    (should (= (aref bytes 0) 0))
    (should (= (aref bytes 1) 0))))


;;; Base32 decoding

(ert-deftest cid-base32-decode-v1 ()
  "Base32 decoding of a known CIDv1 yields expected bytes."
  (let* ((body (substring cid-test--v1-str 1))  ; strip 'b' prefix
         (bytes (cid--base32-decode body cid--base32-lower-alphabet)))
    (should (vectorp bytes))
    (should (> (length bytes) 0))
    (should (equal (cid--encode-hex bytes) cid-test--v1-raw-hex))))

(ert-deftest cid-base32-decode-invalid-char ()
  "Base32 decoding returns nil for strings with invalid characters."
  (should-not (cid--base32-decode "!!!!!" cid--base32-lower-alphabet)))

(ert-deftest cid-base32-decode-padding ()
  "Base32 decoding strips padding characters before decoding."
  (let* ((body (substring cid-test--v1-str 1))
         (padded (concat body "===="))
         (bytes (cid--base32-decode padded cid--base32-lower-alphabet)))
    (should (vectorp bytes))
    (should (equal (cid--encode-hex bytes) cid-test--v1-raw-hex))))

(ert-deftest cid-base32-decode-upper ()
  "Base32 uppercase decoding works with the uppercase alphabet."
  (let ((upper-body (upcase (substring cid-test--v1-str 1)))
        (upper-cid (concat "B" (upcase (substring cid-test--v1-str 1)))))
    (let* ((raw (cid--base32-decode upper-body cid--base32-upper-alphabet))
           (info (cid--parse-v1 upper-cid ?B raw)))
      (should info)
      (should (= (cid-info-version info) 1))
      (should (equal (cid-info-codec info) "dag-pb"))
      (should (equal (cid--encode-hex (cid-info-digest info))
                     cid-test--v1-digest-hex)))))


;;; Base16 decoding

(ert-deftest cid-base16-decode ()
  "Base16 decoding converts hex to bytes."
  (let ((bytes (cid--base16-decode "c0ff")))
    (should (vectorp bytes))
    (should (= (length bytes) 2))
    (should (= (aref bytes 0) #xc0))
    (should (= (aref bytes 1) #xff))))

(ert-deftest cid-base16-decode-odd-length ()
  "Base16 decoding returns nil for odd-length strings."
  (should-not (cid--base16-decode "abc")))

(ert-deftest cid-base16-decode-uppercase ()
  "Base16 decoding handles uppercase hex."
  (let ((bytes (cid--base16-decode "C0FF")))
    (should (vectorp bytes))
    (should (= (length bytes) 2))
    (should (= (aref bytes 0) #xc0))
    (should (= (aref bytes 1) #xff))))

(ert-deftest cid-base16-decode-empty ()
  "Base16 decoding of empty string returns an empty vector."
  (should (equal (cid--base16-decode "") [])))


;;; Varint decoding

(ert-deftest cid-decode-varint-single-byte ()
  "Varint decoding of a single-byte value."
  (let ((result (cid--decode-varint [5] 0)))
    (should result)
    (should (= (car result) 5))
    (should (= (cdr result) 1))))

(ert-deftest cid-decode-varint-multi-byte ()
  "Varint decoding of a multi-byte value."
  (let ((result (cid--decode-varint [#x80 #x01] 0)))
    (should result)
    (should (= (car result) 128))
    (should (= (cdr result) 2))))

(ert-deftest cid-decode-varint-pos ()
  "Varint decoding starting from a non-zero position."
  (let ((result (cid--decode-varint [#xff #x81 #x01] 1)))
    (should result)
    (should (= (car result) 129))
    (should (= (cdr result) 3))))

(ert-deftest cid-decode-varint-truncated ()
  "Varint decoding returns nil when the high bit is set on the last byte."
  (should-not (cid--decode-varint [#x80] 0)))

(ert-deftest cid-decode-varint-out-of-bounds ()
  "Varint decoding returns nil when position is past the vector."
  (should-not (cid--decode-varint [] 0)))


;;; Lookup helpers

(ert-deftest cid-lookup-codec-known ()
  "Known codec codes resolve to strings."
  (should (equal (cid--lookup-codec #x70) "dag-pb"))
  (should (equal (cid--lookup-codec #x55) "raw"))
  (should (equal (cid--lookup-codec #x71) "dag-cbor")))

(ert-deftest cid-lookup-codec-unknown ()
  "Unknown codec codes return a hex string with '(unknown)'."
  (let ((result (cid--lookup-codec #xdead)))
    (should (stringp result))
    (should (string-match-p "0xdead" result))
    (should (string-match-p "unknown" result))))

(ert-deftest cid-lookup-multihash-known ()
  "Known multihash codes resolve to (NAME . SIZE)."
  (should (equal (cid--lookup-multihash #x12) '("sha2-256" . 32)))
  (should (equal (cid--lookup-multihash #x11) '("sha1" . 20))))

(ert-deftest cid-lookup-multihash-unknown ()
  "Unknown multihash codes return nil."
  (should-not (cid--lookup-multihash #xff)))

(ert-deftest cid-multibase-name ()
  "Multibase prefix characters resolve to names."
  (should (equal (cid--multibase-name ?z) "base58btc"))
  (should (equal (cid--multibase-name ?b) "base32"))
  (should (equal (cid--multibase-name ?B) "base32upper"))
  (should (equal (cid--multibase-name ?f) "base16"))
  (should (equal (cid--multibase-name ?F) "base16upper"))
  (should (equal (cid--multibase-name ?c) "base32pad"))
  (should (equal (cid--multibase-name ?C) "base32padupper"))
  (should (equal (cid--multibase-name ?m) "base64"))
  (should (equal (cid--multibase-name ?u) "base64url"))
  ;; Unknown prefix returns nil.
  (should-not (cid--multibase-name ?x)))


;;; encod-hex

(ert-deftest cid-encode-hex ()
  "`cid--encode-hex' converts byte vectors to lowercase hex."
  (should (equal (cid--encode-hex [0 1 255 16]) "0001ff10"))
  (should (equal (cid--encode-hex []) ""))
  (should (equal (cid--encode-hex '(0 127)) "007f")))


;;; CID info struct

(ert-deftest cid-info-struct ()
  "`cid-info--create' produces a proper struct."
  (let ((info (cid-info--create
               :cid-string "test"
               :version 0
               :multibase "base58btc"
               :codec "dag-pb"
               :codec-code #x70
               :multihash-name "sha2-256"
               :multihash-code #x12
               :digest-size 32
               :digest [1 2 3]
               :raw-bytes [4 5 6]
               :errors '("warning"))))
    (should (cid-info-p info))
    (should (equal (cid-info-cid-string info) "test"))
    (should (= (cid-info-version info) 0))
    (should (equal (cid-info-multibase info) "base58btc"))
    (should (equal (cid-info-codec info) "dag-pb"))
    (should (= (cid-info-codec-code info) #x70))
    (should (equal (cid-info-multihash-name info) "sha2-256"))
    (should (= (cid-info-multihash-code info) #x12))
    (should (= (cid-info-digest-size info) 32))
    (should (equal (cid-info-digest info) [1 2 3]))
    (should (equal (cid-info-raw-bytes info) [4 5 6]))
    (should (equal (cid-info-errors info) '("warning")))))


;;; Prefix detection

(ert-deftest cid-detect-prefix-v0 ()
  "CIDv0 detection returns nil (no multibase prefix)."
  (should-not (cid--detect-prefix cid-test--v0-str)))

(ert-deftest cid-detect-prefix-v0-too-short ()
  "Strings shorter than 46 chars are not detected as CIDv0."
  (should (eq (cid--detect-prefix "Qm123") 'unknown-prefix)))

(ert-deftest cid-detect-prefix-v0-not-qm ()
  "Strings of right length but not starting with Qm are not CIDv0."
  (should (eq (cid--detect-prefix "Xm12345678901234567890123456789012345678901234")
              'unknown-prefix)))

(ert-deftest cid-detect-prefix-v1-b ()
  "CIDv1 detection with base32 lowercase prefix."
  (should (= (cid--detect-prefix cid-test--v1-str) ?b)))

(ert-deftest cid-detect-prefix-v1-z ()
  "CIDv1 detection with base58btc prefix."
  (let ((cid "z2VPrDb8EyaUh9FQKRLBGzPBWQxwwcWm1q4PyQYiH5pF9qc"))
    (should (= (cid--detect-prefix cid) ?z))))

(ert-deftest cid-detect-prefix-v1-f ()
  "CIDv1 detection with base16 prefix."
  (let ((cid "f1220c3c4733ec8affd06cf9e9ff50ffc6bcd2ec85a6170004bb709669c31de94391a"))
    (should (= (cid--detect-prefix cid) ?f))))

(ert-deftest cid-detect-prefix-unknown ()
  "Strings with an unknown first character return 'unknown-prefix."
  (should (eq (cid--detect-prefix "xabc123") 'unknown-prefix)))


;;; CIDv0 parsing

(ert-deftest cid-parse-v0-valid ()
  "Parsing a valid CIDv0 yields the expected struct."
  (let* ((raw (cid--base58-decode cid-test--v0-str))
         (info (cid--parse-v0 cid-test--v0-str raw)))
    (should info)
    (should (cid-info-p info))
    (should (= (cid-info-version info) 0))
    (should (equal (cid-info-multibase info) "base58btc"))
    (should (equal (cid-info-codec info) "dag-pb"))
    (should (= (cid-info-codec-code info) #x70))
    (should (equal (cid-info-multihash-name info) "sha2-256"))
    (should (= (cid-info-multihash-code info) #x12))
    (should (= (cid-info-digest-size info) 32))
    (should (equal (cid--encode-hex (cid-info-digest info))
                   cid-test--v0-digest-hex))
    (should (equal (cid-info-raw-bytes info) raw))
    (should-not (cid-info-errors info))))

(ert-deftest cid-parse-v0-empty ()
  "Parsing an empty byte vector returns nil."
  (should-not (cid--parse-v0 "Qm" [])))


;;; CIDv1 parsing

(ert-deftest cid-parse-v1-valid ()
  "Parsing a valid CIDv1 yields the expected struct."
  (let* ((raw (cid--decode-base cid-test--v1-str ?b))
         (info (cid--parse-v1 cid-test--v1-str ?b raw)))
    (should info)
    (should (cid-info-p info))
    (should (= (cid-info-version info) 1))
    (should (equal (cid-info-multibase info) "base32"))
    (should (equal (cid-info-codec info) "dag-pb"))
    (should (= (cid-info-codec-code info) #x70))
    (should (equal (cid-info-multihash-name info) "sha2-256"))
    (should (= (cid-info-multihash-code info) #x12))
    (should (= (cid-info-digest-size info) 32))
    (should (equal (cid--encode-hex (cid-info-digest info))
                   cid-test--v1-digest-hex))
    (should (equal (cid--encode-hex (cid-info-raw-bytes info))
                   cid-test--v1-raw-hex))
    (should-not (cid-info-errors info))))

(ert-deftest cid-parse-v1-unknown-codec ()
  "Parsing with an unknown codec records a warning but still succeeds."
  ;; Construct minimal CIDv1 bytes: version=1, codec=0xff, identity hash on empty.
  (let* ((raw [1 #xff 0 0])
         (info (cid--parse-v1 "f0101ff0000" ?f raw)))
    (should info)
    (should (cid-info-errors info))
    (should (string-match-p "Unknown codec" (car (cid-info-errors info))))))

(ert-deftest cid-parse-v1-wrong-version ()
  "CIDv1 parsing records a warning when the version is not 1."
  ;; Construct bytes with version=2, codec=raw, identity hash.
  (let* ((raw [2 #x55 0 0])
         (info (cid--parse-v1 "test" ?f raw)))
    (should info)
    (should (cid-info-errors info))
    (should (string-match-p "version 1" (car (cid-info-errors info))))))

(ert-deftest cid-parse-v1-digest-size-mismatch ()
  "CIDv1 parsing warns when digest size doesn't match the multihash table."
  ;; Construct bytes: version=1, codec=raw, sha1 header but only 5 digest bytes
  ;; (sha1 expects 20 bytes, but we declare only 5).
  (let* ((raw [1 #x55 #x11 #x05 #x00 #x00 #x00 #x00 #x00])
         (info (cid--parse-v1 "test" ?f raw)))
    (should info)
    (should (cid-info-errors info))
    (should (string-match-p "digest size mismatch" (car (cid-info-errors info))))))

(ert-deftest cid-parse-v1-empty ()
  "Parsing an empty byte vector returns nil."
  (should-not (cid--parse-v1 "test" ?b [])))


;;; cid--decode-base

(ert-deftest cid-decode-base-null-prefix ()
  "Null prefix dispatches to base58btc decoding."
  (should (equal (cid--decode-base cid-test--v0-str nil)
                 (cid--base58-decode cid-test--v0-str))))

(ert-deftest cid-decode-base-unknown-prefix ()
  "Unknown prefix returns nil."
  (should-not (cid--decode-base "xabc" ?x)))


;;; cid--bounds

(ert-deftest cid-bounds-v0 ()
  "`cid--bounds' finds a CIDv0 at point."
  (with-temp-buffer
    (insert "prefix " cid-test--v0-str " suffix")
    (goto-char (+ 8 (length cid-test--v0-str)))  ; middle of CID
    (let ((bounds (cid--bounds)))
      (should bounds)
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     cid-test--v0-str)))))

(ert-deftest cid-bounds-v1 ()
  "`cid--bounds' finds a CIDv1 at point."
  ;; The real CIDv1 test vector contains lowercase l, which is
  ;; legitimate in base32 (the old ambiguous-char heuristic wrongly
  ;; rejected such CIDs).
  (with-temp-buffer
    (insert "prefix " cid-test--v1-str " suffix")
    (goto-char 15) ; inside the CID
    (let ((bounds (cid--bounds)))
      (should bounds)
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     cid-test--v1-str)))))

(ert-deftest cid-bounds-no-cid ()
  "`cid--bounds' returns nil when no CID is at point."
  (with-temp-buffer
    (insert "not a cid here")
    (goto-char 5)
    (should-not (cid--bounds))))

(ert-deftest cid-bounds-cidv0-ambiguous-chars ()
  "`cid--bounds' rejects strings with ambiguous base58 characters."
  (with-temp-buffer
    (insert "Qm1234567890123456789012345678901234567890O")  ; 'O' in base58
    (goto-char 20)
    ;; This is 46 chars but contains 'O' — the v0 regex rejects it.
    ;; It also isn't a valid v1 prefix (Q != known prefix), so bounds returns nil.
    (should-not (cid--bounds))))

(ert-deftest cid-bounds-rejects-lookalike-words ()
  "`cid--bounds' rejects prose words sharing a multibase prefix."
  ;; Words starting with a valid multibase prefix (c, b, z, f, m, u)
  ;; that do not decode to a valid CID framing.
  (dolist (word (list "crate" "cafebabe" "cat" "banana" "base"
                      "color" "coin" "code" "car" "bacon" "zQm"))
    (with-temp-buffer
      (insert "pre " word " post")
      (goto-char (+ 5 (length word)))
      (ert-info ((format "testing word %S" word))
        (should-not (cid--bounds))))))


(ert-deftest cid-bounds-accepts-real-v1-with-l ()
  "`cid--bounds' accepts the real CIDv1 test vector, which contains l."
  (with-temp-buffer
    (insert cid-test--v1-str)
    (goto-char 1)
    (let ((bounds (cid--bounds)))
      (should bounds)
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     cid-test--v1-str)))))


;;; Thing-at-point

(ert-deftest cid-thing-at-point-v0 ()
  "`thing-at-point' returns a CIDv0 when point is on it."
  (with-temp-buffer
    (insert "prefix " cid-test--v0-str " suffix")
    (goto-char 25)
    (should (equal (thing-at-point 'cid) cid-test--v0-str))))

(ert-deftest cid-thing-at-point-v1 ()
  "`thing-at-point' returns a CIDv1 when point is on one."
  (with-temp-buffer
    (insert "prefix " cid-test--v1-str " suffix")
    (goto-char 12)
    (should (equal (thing-at-point 'cid) cid-test--v1-str))))

(ert-deftest cid-thing-at-point-no-cid ()
  "`thing-at-point' returns nil when not on a CID."
  (with-temp-buffer
    (insert "just some nothing text")
    (goto-char 6)
    (should-not (thing-at-point 'cid))))

(ert-deftest cid-thing-at-point-bounds ()
  "`bounds-of-thing-at-point' returns the correct span."
  (with-temp-buffer
    (insert "before " cid-test--v0-str " after")
    (goto-char 20)
    (let ((bounds (bounds-of-thing-at-point 'cid)))
      (should bounds)
      (should (equal (buffer-substring (car bounds) (cdr bounds))
                     cid-test--v0-str)))))


;;; Bookmarks

(ert-deftest cid-bookmark-make-record ()
  "`cid--bookmark-make-record' returns a bookmark record with the CID."
  (let ((cid--info (cid-info--create
                    :cid-string cid-test--v0-str
                    :version 0
                    :multibase "base58btc"
                    :codec "dag-pb"
                    :codec-code #x70
                    :multihash-name "sha2-256"
                    :multihash-code #x12
                    :digest-size 32
                    :digest (cl-subseq (cid--base58-decode cid-test--v0-str) 2)
                    :raw-bytes (cid--base58-decode cid-test--v0-str)
                    :errors nil)))
    (let ((rec (cid--bookmark-make-record)))
      (should (stringp (car rec)))
      (should (string-match-p "CID:" (car rec)))
      (should (eq (alist-get 'handler rec) 'cid-bookmark-jump))
      (should (equal (alist-get 'cid rec) cid-test--v0-str))
      (should (stringp (alist-get 'location rec))))))

(ert-deftest cid-bookmark-make-record-no-info ()
  "`cid--bookmark-make-record' returns nil when `cid--info' is nil."
  (let ((cid--info nil))
    (should-not (cid--bookmark-make-record))))

(ert-deftest cid-bookmark-jump ()
  "`cid-bookmark-jump' delegates to `cid-decode'."
  (let ((called-cid nil))
    (cl-letf (((symbol-function 'cid-decode)
               (lambda (cid) (setq called-cid cid))))
      (cid-bookmark-jump `("CID: test" (cid . ,cid-test--v0-str)))
      (should (equal called-cid cid-test--v0-str)))))

(ert-deftest cid-bookmark-handler-type ()
  "`cid-bookmark-jump' has a `bookmark-handler-type' property."
  (should (equal (get 'cid-bookmark-jump 'bookmark-handler-type) "CID")))


;;; Interactive commands (non-interactive)

(ert-deftest cid-decode-v0 ()
  "`cid-decode' called non-interactively decodes a CIDv0."
  (let ((buf-name (format "*CID: %s*" cid-test--v0-str)))
    ;; Kill any existing buffer from previous runs.
    (when (get-buffer buf-name)
      (kill-buffer buf-name))
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf))))
      (cid-decode cid-test--v0-str)
      (should (eq major-mode 'cid-mode))
      (should cid--info)
      (should (= (cid-info-version cid--info) 0))
      (should (equal (cid-info-cid-string cid--info) cid-test--v0-str))
      (let ((content (buffer-string)))
        (should (string-match-p "CIDv0" content))
        (should (string-match-p "dag-pb" content))
        (should (string-match-p "sha2-256" content))
        (should (string-match-p "base58btc" content)))
      (kill-buffer))))

(ert-deftest cid-decode-v1 ()
  "`cid-decode' called non-interactively decodes a CIDv1."
  (let ((buf-name (format "*CID: %s*" cid-test--v1-str)))
    (when (get-buffer buf-name)
      (kill-buffer buf-name))
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buf) (set-buffer buf))))
      (cid-decode cid-test--v1-str)
      (should (eq major-mode 'cid-mode))
      (should cid--info)
      (should (= (cid-info-version cid--info) 1))
      (should (equal (cid-info-cid-string cid--info) cid-test--v1-str))
      (let ((content (buffer-string)))
        (should (string-match-p "CIDv1" content))
        (should (string-match-p "dag-pb" content))
        (should (string-match-p "sha2-256" content))
        (should (string-match-p "base32" content)))
      (kill-buffer))))

(ert-deftest cid-decode-empty ()
  "`cid-decode' signals an error for an empty string."
  (should-error (cid-decode "") :type 'user-error))

(ert-deftest cid-decode-unknown-prefix ()
  "`cid-decode' signals an error for an unrecognized CID prefix."
  (should-error (cid-decode "xabc") :type 'user-error))

(ert-deftest cid-decode-invalid-base58 ()
  "`cid-decode' signals an error for invalid base58 encoding."
  (should-error (cid-decode "z!!!invalid!!!") :type 'user-error))

(ert-deftest cid-revert-no-info ()
  "`cid-revert' signals an error when `cid--info' is nil."
  (with-temp-buffer
    (cid-mode)
    (should-error (cid-revert) :type 'user-error)))

(ert-deftest cid-copy-cid-no-info ()
  "`cid-copy-cid' signals an error when `cid--info' is nil."
  (with-temp-buffer
    (cid-mode)
    (should-error (cid-copy-cid) :type 'user-error)))

(ert-deftest cid-open-gateway-no-info ()
  "`cid-open-gateway' signals an error when `cid--info' is nil."
  (with-temp-buffer
    (cid-mode)
    (should-error (cid-open-gateway) :type 'user-error)))

;;; Purity declarations

(ert-deftest cid-parsers-declare-purity ()
  "The CID parsers declare purity, so the compiler can fold them.
Both parsers depend only on their arguments and the constant
multibase/multicodec/multihash tables."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "cid-mode.el"))
    (dolist (entry '("cid--parse-v0" "cid--parse-v1"))
      (goto-char (point-min))
      (should (re-search-forward
               (concat "^(defun " (regexp-quote entry) " "
                       "[^\n]*\n[^\n]*\n[^\n]*\n  (declare (pure t) "
                       "(side-effect-free t))") nil t)))))


;;; Major mode

(ert-deftest cid-mode-initialization ()
  "`cid-mode' sets up buffer-local variables correctly."
  (with-temp-buffer
    (cid-mode)
    (should (eq major-mode 'cid-mode))
    (should buffer-read-only)
    (should (eq revert-buffer-function #'cid-revert))
    (should (eq bookmark-make-record-function #'cid--bookmark-make-record))))


;;; Autoloads

(ert-deftest cid-autoloads ()
  "Every user-facing entry point carries an autoload cookie.
A fresh install must reach `cid-decode' and friends without an
explicit require, and the URL handlers must register at startup."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "cid-mode.el"))
    (let ((source (buffer-string)))
      (dolist (entry '("cid-decode" "cid-decode-at-point"
                       "cid-decode-from-raw" "cid-bookmark-jump"))
        (should (string-match-p
                 (format "^;;;###autoload\n(\\(?:defun\\|defmacro\\) %s\\b"
                         (regexp-quote entry))
                 source))))
    ;; Both schemes come from the autoload file, so `ipfs://' and
    ;; `ipns://' work before the first decode.
    (goto-char (point-min))
    (should (= 2 (how-many "^(add-to-list 'browse-url-default-handlers$")))
    (goto-char (point-min))
    (should (search-forward "\n;;;###autoload\n;; browse-url is required above"
                            nil t))
    ;; The Org link type loads with Org, not with the first decode.
    (goto-char (point-min))
    (should (search-forward
             "(with-eval-after-load 'org\n  (require 'ol-cid nil t))"
             nil t))
    (dolist (scheme '("\\`ipfs://" "\\`ipns://"))
      (should (assoc scheme browse-url-default-handlers)))))

(ert-deftest embark-cid-autoloads ()
  "Embark entry points carry autoload cookies.
A fresh install must reach `embark-cid-copy' and friends without an
explicit require, and loading Embark must load the module."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "embark-cid.el"))
    (let ((source (buffer-string)))
      (dolist (entry '("embark-cid-target-at-point" "embark-cid-decode"
                       "embark-cid-copy" "embark-cid-open-gateway"))
        (should (string-match-p
                 (format "^;;;###autoload\n(\\(?:defun\\|defmacro\\) %s\\b"
                         (regexp-quote entry))
                 source))))
    ;; The registration form comes from the autoloads file, so Embark
    ;; finds CIDs before the module is loaded.
    (goto-char (point-min))
    (should (search-forward
             (concat "\n;;;###autoload\n"
                     "(with-eval-after-load 'embark\n"
                     "  (add-hook 'embark-target-finders "
                     "#'embark-cid-target-at-point)")
             nil t))))


(provide 'cid-tests)
;;; cid-tests.el ends here

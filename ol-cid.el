;;; ol-cid.el --- Org links to IPFS Content Identifiers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, ipfs, org
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

;; Org link type for IPFS Content Identifiers.
;;
;;   [[cid:QmXoypizjW3WknFiJnKLwHCnL72vedxjQkDDP1mXWo6uco][my CID]]
;;   [[cid:bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi]]
;;
;; This module is opt-in: it does a plain (require 'ol) and users
;; enable it with (with-eval-after-load 'org (require 'ol-cid)) in
;; their config.  See also `cid-mode' for the interactive CID
;; decoder.

;;; Code:

(require 'ol)

(declare-function cid-decode "cid-mode")
(declare-function cid-info-cid-string "cid-mode")
(declare-function cid-mode "cid-mode")

(defvar cid--info)
(defvar cid-gateway-url)

(defun cid--org-store-link (_interactive-p)
  "Store a `cid:' link when in `cid-mode'."
  (when (eq major-mode 'cid-mode)
    (when-let* ((cid-string (and (boundp 'cid--info) cid--info
                                 (cid-info-cid-string cid--info))))
      (org-link-store-props :type "cid"
                            :link (format "cid:%s" cid-string)
                            :description (format "CID: %s" cid-string))
      t)))

(defun cid-org-export (path description backend _info)
  "Export a `cid:' link to an IPFS gateway URL.
PATH is the CID string, DESCRIPTION is the link text,
BACKEND is the export backend."
  (let ((url (format "%s/ipfs/%s" cid-gateway-url (url-hexify-string path)))
        (desc (or description path)))
    (pcase backend
      ('html (format "<a href=\"%s\">%s</a>" url desc))
      ('latex (format "\\href{%s}{%s}" url desc))
      (_ desc))))

(defun cid--org-follow (path)
  "Follow a `cid:' link by decoding PATH with `cid-decode'.
If a buffer already exists for this CID, switch to it instead."
  (let ((bufname (format "*CID: %s*" path)))
    (if-let* ((buf (get-buffer bufname)))
        (pop-to-buffer buf)
      (cid-decode path))))

(defun cid--org-complete (&optional _)
  "Complete a `cid:' link, prompting for a CID string."
  (concat "cid:" (read-string "CID: ")))


(org-link-set-parameters "cid"
                         :follow #'cid--org-follow
                         :complete #'cid--org-complete
                         :store #'cid--org-store-link
                         :export #'cid-org-export)

(provide 'ol-cid)
;;; ol-cid.el ends here

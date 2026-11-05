;;; embark-cid.el --- Embark actions for CIDs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools, ipfs
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

;; Embark integration for CID actions.  When point is on a CID,
;; `embark-act' offers actions: decode, copy, open on gateway.
;;
;; Every entry point carries an autoload cookie, so the module needs no
;; explicit require.  The finder and the commands are autoloaded, and the
;; registration form below runs from the autoloads file, so the first
;; `embark-act' on a CID loads this file on demand.  Users can also load
;; the module by hand:
;;
;;   (require 'embark-cid)

;;; Code:

;; `cid--bounds' has no autoload cookie, so `declare-function' would
;; not load it.  Load the package.
(require 'cid-mode)

(defvar embark-keymap-alist)
(defvar embark-target-finders)

;;; Target finder and actions

;;;###autoload
(defun embark-cid-target-at-point ()
  "Target a CID at point for Embark."
  (when-let* ((bounds (cid--bounds))
              (cid-str (buffer-substring-no-properties
                        (car bounds) (cdr bounds))))
    `(ipfs-cid ,cid-str ,(car bounds) . ,(cdr bounds))))

;;;###autoload
(defun embark-cid-decode (cid)
  "Open a CID decoding buffer for CID."
  (interactive "sCID: ")
  (cid-decode cid))

;;;###autoload
(defun embark-cid-copy (cid)
  "Copy CID to the kill ring."
  (interactive "sCID: ")
  (kill-new cid)
  (message "Copied: %s" cid))

;;;###autoload
(defun embark-cid-open-gateway (cid)
  "Open CID on the configured IPFS gateway."
  (interactive "sCID: ")
  (browse-url (format "%s/ipfs/%s" cid-gateway-url cid)))

(defvar-keymap embark-cid-map
  :doc "Keymap for Embark CID actions."
  :parent nil
  "RET" #'embark-cid-decode
  "w"   #'embark-cid-copy
  "b"   #'embark-cid-open-gateway)

;;; Register with Embark (deferred until Embark is loaded)

;;;###autoload
(with-eval-after-load 'embark
  (add-hook 'embark-target-finders #'embark-cid-target-at-point)
  (add-to-list 'embark-keymap-alist '(ipfs-cid . embark-cid-map)))

(provide 'embark-cid)
;;; embark-cid.el ends here

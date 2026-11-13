;;; cid-mode-test-helper.el --- Shared helpers for cid-mode tests -*- lexical-binding: t -*-

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

;;; Commentary:

;; Fixtures shared by the cid-mode ERT files.  The file name ends in
;; `-helper.el' rather than `-test.el', so the glob loader in
;; `flake.nix' treats it as support code, not as a test file.

;;; Code:

(defconst cid-mode-test--test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory that holds the test files.")

(defconst cid-mode-test--source-directory
  (expand-file-name ".." cid-mode-test--test-directory)
  "Directory that holds the package sources.")

(defun cid-mode-test--source-contents (file)
  "Return the contents of source FILE, named relative to the package root.
Some tests read the source text itself, for example to assert on
autoload cookies.  Resolve the path from this file, so the suite
runs from any working directory."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file cid-mode-test--source-directory))
    (buffer-string)))

(provide 'cid-mode-test-helper)
;;; cid-mode-test-helper.el ends here

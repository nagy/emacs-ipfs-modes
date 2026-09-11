{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

let
  # magit-section plus everything it transitively requires (compat,
  # cond-let, llama, seq, ...).  These must be on `load-path' for the
  # ERT suite, which loads cid-mode.el from the source tree.
  elpaDeps = lib.closePropagation [ emacsPackages.magit-section ];
in

melpaBuild {
  pname = "cid-mode";
  version = "0.1.0-unstable-2026-07-25";

  # `./..' is the repo root: this expression lives in nix/ but the
  # package sources and tests sit one level up.
  src = lib.cleanSource ./..;

  packageRequires = [ emacsPackages.magit-section ];

  turnCompilationWarningToError = true;

  # melpaBuild byte-compiles with warnings-as-errors; add the ERT
  # suite here so `nix flake check' runs it too.  The dependencies are
  # not activated at check time, so push each elpa subdirectory onto
  # `load-path' explicitly.
  checkPhase = ''
    runHook preCheck
    extra=()
    for dep in ${lib.concatMapStringsSep " " toString elpaDeps}; do
      for dir in "$dep"/share/emacs/site-lisp/elpa/*; do
        extra+=(-L "$dir")
      done
    done
    emacs --batch -L . "''${extra[@]}" \
      -l cid-tests.el -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Decode and browse IPFS Content Identifiers from Emacs";
    longDescription = ''
      cid-mode is an Emacs major mode for decoding and browsing IPFS
      Content Identifiers (CIDs), similar to the online tool at
      https://cid.ipfs.tech/.  It decodes both CIDv0 (base58btc, dag-pb)
      and CIDv1 (any multibase, any codec) into their components:
      version, multibase encoding, multicodec, multihash algorithm, and
      digest.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/emacs-ipfs-modes";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}

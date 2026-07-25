{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

melpaBuild {
  pname = "cid-mode";
  version = "0.1.0-unstable-2026-07-08";

  src = lib.cleanSource ./.;

  packageRequires = [ ];

  turnCompilationWarningToError = true;

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

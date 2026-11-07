{
  description = "Decode and browse IPFS Content Identifiers from Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Provides lib/git.nix with mkGitRepository, used to publish the
    # README screenshot as a git branch.  Not a flake itself, so it is
    # fetched as a plain source tree and imported directly.
    nur-packages = {
      url = "github:nagy/nur-packages";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nur-packages,
      ...
    }:
    let
      # Date of the last commit as YYYY-MM-DD, folded into the version
      # string.  Flake source info gives it as e.g. "20260922133522";
      # slice out the year, month and day.  A plain path import has no
      # git metadata, so fall back to the epoch instead of failing.
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
      version = "0.1.0-unstable-${commitDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Elisp is architecture-independent and every dependency
      # (Emacs, magit-section, image tooling) is available on both
      # Linux architectures, so evaluate on the full set.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          ...
        }:
        let
          lib = pkgs.lib;

          # The package stays overridable, so a consumer can swap the
          # Emacs that supplies magit-section:
          #   inputs.emacs-ipfs-modes.packages.${system}.cid-mode.override {
          #     emacs = pkgs.emacs-nox;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          cidModeEl = lib.makeOverridable (
            {
              # One Emacs package set supplies every dependency, so an
              # override of this argument moves all of them.
              emacs ? pkgs.emacs,
              # `melpaBuild' closes over the Emacs of its package set, so
              # an `emacs' argument on the build does nothing.  Build the
              # set against a wrapper instead, one that carries
              # magit-section on its load path, so the install
              # byte-compile and the ERT suite find the library without a
              # manual `-L' per elpa subdirectory.
              emacsPackages ? pkgs.emacsPackagesFor (emacs.pkgs.withPackages (_: [ emacs.pkgs.magit-section ])),
              melpaBuild ? emacsPackages.melpaBuild,
              version ? "0.1.0",
            }:
            melpaBuild {
              pname = "cid-mode";
              inherit version;

              src = lib.cleanSource ./.;

              # The installed directory name comes from `pname' + `version',
              # while package.el reads `;; Version:' from the header.  Keep
              # both equal so package-lint, package.el and the store path
              # agree.
              postPatch = ''
                substituteInPlace cid-mode.el ol-cid.el embark-cid.el \
                  --replace-fail ';; Version: 0.1.0' ';; Version: ${version}'
              '';

              packageRequires = [ emacsPackages.magit-section ];

              turnCompilationWarningToError = true;

              # melpaBuild byte-compiles with warnings-as-errors; add the
              # ERT suite here so `nix flake check' runs it too.  The
              # wrapped Emacs already carries magit-section and its
              # transitive dependencies on the load path.
              checkPhase = ''
                runHook preCheck
                emacs --batch -L . -l cid-tests.el -f ert-run-tests-batch-and-exit
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
          ) { inherit version; };

          # Screenshot.  Kept out of `checks' because it boots Emacs
          # under Xvfb; the ERT suite already covers the rendering code.
          screenshot = pkgs.callPackage ./nix/emacs-screenshot.nix {
            inherit cidModeEl;
            # lib.mkGitRepository comes from the nur-packages input
            # rather than a vendored copy; only the one file is needed.
            nurLib = import "${nur-packages}/lib/git.nix" { inherit pkgs; };
          };
        in
        {
          packages = {
            cid-mode = cidModeEl;
            default = cidModeEl;

            # README screenshot, dual light/dark SVG (gitrepo is the
            # bare `.git' directory ready to push to the branch the
            # README links to — kept out of `checks` on purpose).
            screenshot = screenshot.svg;
            inherit (screenshot) gitrepo;
          };

          checks = {
            # melpaBuild already byte-compiles with warnings-as-errors;
            # `cid-mode' also runs the ERT suite in its checkPhase, so
            # it is the check.
            default = cidModeEl;
            inherit cidModeEl;
          };

          # Dev shell: Emacs plus the tools the ERT suite shells out to.
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.emacs
              pkgs.nix
            ];
          };

          formatter = pkgs.nixfmt;
        };
    };
}

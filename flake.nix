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
              #
              # melpaBuild stages only the files matched by `files' (root
              # `*.el'), so bring the test tree back before loading it.
              # The tests outnumber the files, so load them with a glob:
              # a new test file then needs no edit here.  printf repeats
              # "-l %s" once per match, which turns the glob into `-l
              # <file>' pairs.  failglob makes an empty glob a shell
              # error, so the || guard fires instead of passing with
              # zero tests.  The unquoted $test_args must split into
              # words, which stays safe because test names hold no
              # spaces.  `-L test' lets each file require the helper.
              checkPhase = ''
                runHook preCheck
                cp -r ${./test} ./test
                shopt -s failglob
                test_args=$(printf -- "-l %s " test/*-test.el) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
                shopt -u failglob
                emacs --batch -L . -L test $test_args -f ert-run-tests-batch-and-exit
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

            # Static lint gate.  Byte compilation cannot see a bad header,
            # a stray symbol prefix or an undocumented argument, so run
            # package-lint and checkdoc over the sources and the tests.
            lint =
              pkgs.runCommand "cid-mode-lint"
                {
                  nativeBuildInputs = [
                    # magit-section is not in the offline ELPA index that the
                    # sandbox sees, so package-lint needs a stub entry.  Give
                    # Emacs a private HOME so its caches stay in the build.
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                    pkgs.writableTmpDirAsHomeHook
                  ];
                  # `src' is the pre-postPatch tree, which is what should be
                  # linted: postPatch only rewrites the `;; Version:' header.
                  src = cidModeEl.src;
                }
                ''
                  # Copy instead of relying on what melpaBuild staged, because
                  # test/ is part of the lint surface.
                  cp -r "$src"/. .

                  # `package-lint-main-file' makes every file lint against the
                  # main package headers.  Two prefix families come from other
                  # packages by design: `magit-cid-*-section-map' (the
                  # magit-section naming convention) and `embark-cid-*'.  The
                  # deferred loads in the autoload cookies must stay, so the
                  # eval-after-load warning is turned off.  The double
                  # backslashes reach Emacs, which reads them as regex
                  # alternation.
                  emacs --batch --eval "(require 'package)" -l package-lint \
                    --eval '(setq package-lint-main-file "cid-mode.el")' \
                    --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|magit-cid\\|embark-cid"))' \
                    --eval '(advice-add (quote package-lint--check-eval-after-load) :override (lambda () nil))' \
                    --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote magit-section) (list (package-desc-create :name (quote magit-section) :version (quote (3 3 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                    -f package-lint-batch-and-exit \
                    *.el test/*.el

                  # checkdoc exits 0 even when it finds problems, so gate on
                  # non-empty output instead of on the exit status.
                  lint_log=$(emacs --batch -l checkdoc \
                    --eval '(setq checkdoc-arguments-in-order-flag t)' \
                    --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
                    *.el test/*.el 2>&1)
                  if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi

                  touch $out
                '';
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

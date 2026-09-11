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
          # The package expression lives in nix/ to keep this file lean.
          cidModeEl = pkgs.callPackage ./nix/default.nix { };

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

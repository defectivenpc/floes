{
  description = "floe: typed interfaces and mixin linking for Nix modules";

  # The library is `lib`, and it takes nixpkgs' `lib` and nothing else. A
  # consumer needs no system, so `lib` is a flake-level output; the checks
  # need one, and are per-system.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
    }:
    {
      # mkFloeLib :: nixpkgs.lib -> the library
      #
      # What a consumer with its own nixpkgs calls, so one `lib` reaches
      # both and floe's pin decides nothing downstream.
      mkFloeLib = lib: import ./lib { inherit lib; };

      # The same against this flake's own pin, for a reader with no nixpkgs
      # to hand — `nix eval github:defectivenpc/floes#lib.T`.
      lib = import ./lib { lib = nixpkgs.lib; };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;

        treefmtEval = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix);

        results = import ./tests { inherit lib; };

        examples = import ./examples {
          inherit lib;
          floe = self.lib;
        };

        # The NixOS example's fragments, handed to NixOS. Forcing the toplevel
        # derivation's path evaluates the whole configuration, which is what
        # proves the fragments are valid config and not merely well-typed data
        # — a snapshot cannot tell a real option path from a plausible one.
        #
        # The context is discarded deliberately: this check should evaluate a
        # NixOS system, not build one.
        exampleSystem = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = examples.nixos.nixosModules ++ [
            {
              boot.loader.grub.devices = [ "/dev/sda" ];
              fileSystems."/" = {
                device = "/dev/sda1";
                fsType = "ext4";
              };
              system.stateVersion = "24.05";
            }
          ];
        };
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        checks = {
          formatting = treefmtEval.config.build.check self;

          tests = pkgs.runCommand "floe-tests" { } ''
            cat <<'EOF' > $out
            ${builtins.toJSON results}
            EOF
            if [ ${toString (builtins.length results)} -ne 0 ]; then
              echo "floe tests FAILED:" >&2
              cat $out >&2
              exit 1
            fi
          '';

          examples-nixos-system = pkgs.runCommand "floe-examples-nixos-system" { } ''
            echo ${builtins.unsafeDiscardStringContext exampleSystem.config.system.build.toplevel.drvPath} > $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [ treefmtEval.config.build.wrapper ];
        };
      }
    );
}

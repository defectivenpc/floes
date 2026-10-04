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
      # to hand: `nix eval github:defectivenpc/floes#lib.T`.
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
        # proves the fragments are valid config rather than well-typed data:
        # a snapshot cannot tell a real option path from a plausible one.
        #
        # Discarding the context is the point: this check should evaluate a
        # NixOS system, not build one.
        exampleSystem =
          mods:
          nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = mods ++ [
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

          # Both links, evaluated as real NixOS systems. The small one is the
          # readable example; the fleet is twenty-nine floes, and the only thing
          # that proves the whole set merges rather than just type-checks.
          examples-nixos-system = pkgs.runCommand "floe-examples-nixos-system" { } ''
            echo ${builtins.unsafeDiscardStringContext (exampleSystem examples.nixos.nixosModules).config.system.build.toplevel.drvPath} > $out
          '';

          # `T.package` against a real derivation, which is the only place one
          # exists: `examples/` is `pkgs`-free by design, and `tests/` is
          # evaluated with `lib` alone so it needs no store. The unit suite
          # checks the type against a derivation-shaped attrset; this checks it
          # against `pkgs.hello`.
          #
          # What it checks is the scan. A derivation is an attrset
          # whose `out` is itself, so walking one is a stack overflow, and an
          # uncatchable one, which made a package in `out` take down any link
          # whose sites were read. Any NixOS module writing
          # `environment.systemPackages` puts one there.
          packages-in-output =
            let
              OUT = self.lib.mkSig {
                name = "nixos.config";
                canonicalName = "nixosConfig";
                description = "A fragment of NixOS `config`, for the package check.";
                fields = {
                  environment = self.lib.T.record {
                    systemPackages = self.lib.T.listOf self.lib.T.package;
                  };
                };
              };

              floe = self.lib.mkFloe {
                name = "with-packages";
                summary = "Emits a real derivation, the way a service module does.";
                inputs.package = lib.mkOption { type = lib.types.package; };
                out.nixosConfig = OUT;
                body =
                  { inputs, ... }:
                  {
                    out.nixosConfig.environment.systemPackages = [ inputs.package ];
                  };
              };

              linked = self.lib.link {
                units.hello = floe.instantiate { package = pkgs.hello; };
              };

              emitted = lib.head linked.out."nixos.config".hello.environment.systemPackages;
            in
            pkgs.runCommand "floe-packages-in-output"
              {
                # Forcing the site list is the half that used to crash.
                sites = toString (builtins.length linked.deferredSites);
                path = "${emitted}";
              }
              ''
                test "$sites" = "0" || { echo "expected no deferred sites, got $sites" >&2; exit 1; }
                case "$path" in
                  /nix/store/*-hello-*) ;;
                  *) echo "expected a hello store path, got $path" >&2; exit 1 ;;
                esac
                echo "$path" > $out
              '';

          examples-nixos-fleet = pkgs.runCommand "floe-examples-nixos-fleet" { } ''
            echo ${builtins.unsafeDiscardStringContext (exampleSystem examples.nixos.fleetNixosModules).config.system.build.toplevel.drvPath} > $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [ treefmtEval.config.build.wrapper ];
        };
      }
    );
}

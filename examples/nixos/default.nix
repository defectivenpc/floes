# A NixOS distribution built on floe, and the adapter that hands its output
# back to NixOS.
#
# The probe this exists to run: can a service contribute to a namespace it does
# not own, without writing a global option? `networking.nix` owns
# `networking.*`, `nginx` and `postgres` contribute PORT_CLAIMs, and nothing
# else in the link emits `networking`. See `docs/adr/0001`.
{ lib, floe }:

let
  sigs = import ./sigs.nix { inherit floe; };
  kinds = import ./kinds.nix { inherit floe; };

  mk =
    path:
    import path {
      inherit
        lib
        floe
        sigs
        kinds
        ;
    };

  floes = {
    networking = mk ./networking.nix;
    nginx = mk ./nginx.nix;
    postgres = mk ./postgres.nix;
    webapp = mk ./webapp.nix;
    caddy = mk ./caddy.nix;
  };

  units = import ./system.nix { inherit floes; };

  link = floe.link { inherit units; };

  # ---- The adapter ------------------------------------------------------
  #
  # Every fragment, as an ordinary NixOS module. This is the entire bridge:
  # `out."nixos.config"` is an attrset keyed by unit, each value a fragment of
  # `config`, and the module system merges them the way it merges anything.
  #
  # There is no guard against a deferred value reaching here, because there
  # cannot be one: every fragment is checked against its floe's own output
  # schema, and `T.deferred` where a concrete type is declared is already an
  # error at link. `lib/types.nix` does it, naming the floe the value came from.
  toNixosModules =
    result:
    lib.mapAttrsToList (unit: fragment: {
      _file = "floe:${unit}";
      config = fragment;
    }) result.out."nixos.config";
in
{
  inherit
    sigs
    kinds
    floes
    units
    link
    toNixosModules
    ;

  nixosModules = toNixosModules link;

  # What a deployer writes, in meaningful lines. Blank lines and comments do
  # not count; everything else does, including the function head.
  deployerLines =
    let
      lines = lib.splitString "\n" (builtins.readFile ./system.nix);
    in
    lib.length (lib.filter (l: builtins.match "[[:space:]]*(#.*)?" l == null) lines);

  # ---- The two failure demonstrations ----------------------------------

  # Two providers of REVERSE_PROXY. `webapp`'s hole is exactly-one, so this
  # link fails naming both.
  ambiguousProxy = floe.link {
    units = units // {
      caddy = floes.caddy.instantiate { };
    };
  };

  # The same link, with the deployer saying which one webapp means.
  boundProxy = floe.link {
    units = units // {
      caddy = floes.caddy.instantiate { };
      webapp = (floes.webapp.instantiate { }).bind { proxy = "nginx"; };
    };
  };

  # Two services claiming one port. `networking` owns the namespace, so it is
  # `networking`'s error and it names both claimants.
  portCollision = floe.link {
    units = units // {
      pgbouncer = floes.postgres.instantiate { };
    };
  };

  # The three deliberate mistakes, each linked on its own so a test can hold
  # one at a time. `broken.nix` says what each is and what it costs.
  broken =
    let
      bad = import ./broken.nix {
        inherit
          lib
          floe
          sigs
          kinds
          ;
      };
    in
    lib.mapAttrs (
      _: def:
      floe.link {
        units = units // {
          offender = def.instantiate { };
        };
      }
    ) bad;
}

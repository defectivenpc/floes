# A NixOS distribution built on floe, and the adapter that hands its output
# back to NixOS.
#
# Two links from one set of floes: `small` is the readable one the README shows,
# `fleet` is thirty instances for measuring what the small one cannot show.
# See `docs/adr/0001`.
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
    caddy = mk ./caddy.nix;
    postgres = mk ./postgres.nix;
    webapp = mk ./webapp.nix;
    metrics = mk ./metrics.nix;
    backup = mk ./backup.nix;
  };

  units = import ./system-small.nix { inherit floes; };
  fleetUnits = import ./system-fleet.nix { inherit lib floes; };

  link = floe.link { inherit units; };
  # One line so that adding the second and third database did not break the
  # seventeen consumers that had no opinion about which one they wanted.
  fleet = floe.link {
    units = fleetUnits;
    defaults.DATABASE = "main";
  };

  # ---- The adapter ------------------------------------------------------
  #
  # Every fragment, as an ordinary NixOS module. This is the entire bridge:
  # `out."nixos.config"` is an attrset keyed by unit, each value a fragment of
  # `config`, and the module system merges them the way it merges anything.
  #
  # `_file` is what makes a collision legible: two floes writing one option path
  # produce NixOS's own conflict error naming `floe:<unit>` on both sides.
  #
  # There is no guard against a deferred value reaching here, because there
  # cannot be one: every fragment is checked against its floe's own output
  # schema, and `T.runtime` where a concrete type is declared is already an
  # error at link. `lib/types.nix` does it, naming the floe the value came from.
  toNixosModules =
    result:
    lib.mapAttrsToList (unit: fragment: {
      _file = "floe:${unit}";
      config = fragment;
    }) result.out."nixos.config";

  # What a deployer writes, in meaningful lines: blanks and comments excluded,
  # everything else counted, including the function head.
  linesOf =
    path:
    lib.length (
      lib.filter (l: builtins.match "[[:space:]]*(#.*)?" l == null) (
        lib.splitString "\n" (builtins.readFile path)
      )
    );

  # A `.bind` is the ceremony a second provider forces on every consumer of the
  # signature. Counting them is the only honest way to argue about whether
  # exactly-one resolution scales.
  bindsIn = us: lib.count (u: (u.bindings or { }) != { }) (lib.attrValues us);
in
{
  inherit
    sigs
    kinds
    floes
    units
    fleetUnits
    link
    fleet
    toNixosModules
    ;

  nixosModules = toNixosModules link;
  fleetNixosModules = toNixosModules fleet;

  # ---- What the deployer pays -------------------------------------------

  deployerCost = {
    small = {
      lines = linesOf ./system-small.nix;
      unitCount = lib.length (lib.attrNames units);
      binds = bindsIn units;
    };
    fleet = {
      lines = linesOf ./system-fleet.nix;
      unitCount = lib.length (lib.attrNames fleetUnits);
      binds = bindsIn fleetUnits;
    };
  };

  # ---- The escape hatch, such as it is ---------------------------------
  #
  # A deployer needs nginx's `clientMaxBodySize`. `nginx.nix` does not expose it
  # as an input, and there is nothing else to reach for: `.bind` picks providers,
  # `instantiate` only takes declared inputs, and there is no `floe.extend`. This
  # is failure mode 3 from the design discussion — the Helm `values.yaml`
  # complaint, and reportedly the number one complaint about Helm.
  #
  # The honest answers are two. Fork the floe. Or patch the fragment on its way
  # out, which works today with no library support at all, because the adapter is
  # the deployer's own function:
  patchedNginx =
    let
      patch =
        result:
        result
        // {
          out = result.out // {
            "nixos.config" = lib.recursiveUpdate result.out."nixos.config" {
              nginx.services.nginx.clientMaxBodySize = "64m";
            };
          };
        };
    in
    toNixosModules (patch link);
  #
  # And the cost is the post-renderer's cost, which is why this is recorded
  # rather than recommended. The patch names an option path inside a floe's
  # output, so it depends on internals the floe never promised and nothing warns
  # when they move. Sealing protects `provides`; it does not protect `out`.
  #
  # Note also what the patch cannot do: it edits the *fragment*, after the link.
  # It cannot change anything another floe read through a signature, because that
  # already happened. An escape hatch here can never be as powerful as `mkForce`
  # on a shared option tree, and that is the trade, not an oversight.

  # ---- The failure demonstrations --------------------------------------

  # Two providers of REVERSE_PROXY. `webapp`'s hole is exactly-one, so this link
  # fails naming both.
  ambiguousProxy = floe.link {
    units = units // {
      caddy = floes.caddy.instantiate { };
    };
  };

  # The same link, with the deployer saying which one webapp means.
  boundProxy = floe.link {
    units = units // {
      caddy = floes.caddy.instantiate { };
      webapp = (floes.webapp.instantiate { }).bind {
        proxy = "nginx";
        database = "main";
      };
    };
  };

  # Two postgres instances on the same port. `networking` owns the namespace, so
  # it is `networking`'s error, and it names both claimants.
  portCollision = floe.link {
    units = units // {
      duplicate = floes.postgres.instantiate { port = 5432; };
    };
  };

  # Two nginx instances. It declares itself a singleton because its body writes
  # `services.nginx` rather than keying by `config.floe.name`, so both fragments
  # would be *identical* — and identical values merge without complaint. The
  # deployer would get one proxy and believe they had two. This is the only
  # failure in the example that nothing downstream can catch.
  twoSingletons = floe.link {
    units = units // {
      nginx2 = floes.nginx.instantiate { };
    };
  };

  # Two workloads claiming one hostname. `nginx` owns the vhost namespace, and
  # `mapAttrs'` would otherwise have silently kept one of them.
  hostnameCollision = floe.link {
    units = units // {
      other = (floes.webapp.instantiate { subdomain = "webapp"; }).bind { database = "main"; };
    };
  };

  # The three deliberate mistakes, each linked on its own so a test can hold one
  # at a time. `broken.nix` says what each is and what it costs.
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
        # Without this the offender's DATABASE hole is ambiguous — two postgres
        # instances answer it — and each of these links would fail on *that*
        # instead of on the mistake it exists to demonstrate. Which is the
        # clearest argument for `defaults` there is: one line, and every
        # consumer that has no opinion keeps working.
        defaults.DATABASE = "main";
      }
    ) bad;
}

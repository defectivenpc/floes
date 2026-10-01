# Floes that are wrong on purpose, and the three different qualities of error
# you get for it. This file is the honest half of the example: two of these
# produce a message that names the problem, and one does not.
{
  lib,
  floe,
  sigs,
  kinds,
}:

let
  T = floe.T;
in
{
  # 1. A structural read inside a cycle.
  #
  # This floe contributes a PORT_CLAIM *and* branches on `openPorts`, which is
  # the merge of every PORT_CLAIM. So computing its claim needs the merge, and
  # the merge needs its claim. Nix says `infinite recursion encountered` and
  # names neither floe, neither hole, nor the field responsible.
  #
  # Note what decides it: `nginx` requires the same hole from the same floe in
  # the same cycle and is completely fine, because it reads `domain`. The
  # *field* is what makes this fatal, which is why the polarity annotation
  # RFC 0001 leaves open would have to be per field rather than per hole.
  greedy = floe.mkFloe {
    name = "greedy";
    summary = "Broken on purpose: reads the merge it contributes to.";

    requires.network = sigs.NETWORK;
    provides.ports = sigs.PORT_CLAIM;
    out.nixosConfig = kinds.nixosConfig (T.record { services = T.attrsOf T.any; });

    modules = [
      (
        { config, ... }:
        {
          config.floe.provides.ports.tcp =
            if lib.elem 9000 config.floe.requires.network.openPorts then [ 9001 ] else [ 9000 ];
          config.floe.out.nixosConfig.services = { };
        }
      )
    ];
  };

  # 2. A deferred value used where a concrete one is required.
  #
  # `DATABASE.password` does not exist until postgres has started. Assigning it
  # into a field the output schema types as a string is caught by the linker,
  # which names the floe it came from and when it resolves. This is the error
  # the README claims: a deploy-time failure moved to `nix eval`.
  leaky = floe.mkFloe {
    name = "leaky";
    summary = "Broken on purpose: puts a deferred secret in NixOS config.";

    requires.database = sigs.DATABASE;
    out.nixosConfig = kinds.nixosConfig (
      T.record {
        systemd = T.record {
          services = T.attrsOf (T.record { environment = T.attrsOf T.str; });
        };
      }
    );

    modules = [
      (
        { config, ... }:
        {
          config.floe.out.nixosConfig.systemd.services.leaky.environment.DB_PASSWORD =
            config.floe.requires.database.superuserPassword;
        }
      )
    ];
  };

  # 3. The same mistake, written as string interpolation.
  #
  # Here the token is coerced before anything typed ever sees it, so the error
  # is Nix's: "cannot coerce a set to a string: { __deferred = true; ... }".
  # It is worse than (2) — no path, no explanation — but not useless, because
  # Nix prints the token and `source = "postgres"` is right there in it.
  #
  # This is RFC 0001's open question 1, deferred transparency in interpolation,
  # still open. It is the one place in this example where the diagnosis comes
  # from the reader rather than from floe.
  interpolating = floe.mkFloe {
    name = "interpolating";
    summary = "Broken on purpose: interpolates a deferred secret into a string.";

    requires.database = sigs.DATABASE;
    out.nixosConfig = kinds.nixosConfig (
      T.record {
        systemd = T.record {
          services = T.attrsOf (T.record { environment = T.attrsOf T.str; });
        };
      }
    );

    modules = [
      (
        { config, ... }:
        let
          db = config.floe.requires.database;
        in
        {
          config.floe.out.nixosConfig.systemd.services.interpolating.environment.DATABASE_URL =
            "postgresql://admin:${db.superuserPassword}@${db.host}:${toString db.port}/app";
        }
      )
    ];
  };
}

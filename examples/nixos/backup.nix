# A consumer that exists to be counted.
#
# It requires a DATABASE and nothing else, so in the fleet link — where three
# postgres instances answer DATABASE — every one of these must be told which it
# means. That is the ceremony cost, and `deployerCost` in `default.nix` counts
# it rather than arguing about it.
{
  lib,
  floe,
  sigs,
  kinds,
}:

let
  T = floe.T;
in
floe.mkFloe {
  name = "backup";
  summary = "A nightly dump of one database to local disk.";

  inputs.startAt = lib.mkOption {
    type = lib.types.str;
    default = "03:00";
    description = "When to run.";
  };

  requires.database = sigs.DATABASE;

  out.nixosConfig = kinds.nixosConfig (
    T.record {
      systemd = T.record {
        services = T.attrsOf (
          T.record {
            description = T.str;
            serviceConfig = T.attrsOf T.str;
          }
        );
        timers = T.attrsOf (
          T.record {
            wantedBy = T.listOf T.str;
            timerConfig = T.attrsOf T.str;
          }
        );
      };
    }
  );

  modules = [
    (
      { config, ... }:
      let
        inst = config.floe.name;
        db = config.floe.requires.database;
      in
      {
        config.floe.out.nixosConfig.systemd = {
          services.${inst} = {
            description = "Dump ${toString db.host}:${toString db.port} nightly";
            serviceConfig = {
              Type = "oneshot";
              DynamicUser = "true";
              # The path, never the secret: `db.password` is deferred and would
              # be an eval error here.
              LoadCredential = "dbpw:${db.passwordFile}";
              ExecStart = "/run/current-system/sw/bin/pg_dump -h ${db.host} -p ${toString db.port}";
            };
          };
          timers.${inst} = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = config.floe.inputs.startAt;
              Persistent = "true";
            };
          };
        };
      }
    )
  ];
}

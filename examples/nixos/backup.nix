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

  body =
    {
      inputs,
      requires,
      collects,
      floe,
    }:
    let
      inst = floe.name;
      db = requires.database;
    in
    {
      out.nixosConfig.systemd = {
        services.${inst} = {
          description = "Dump every database on ${toString db.host}:${toString db.port} nightly";
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = "true";

            # The *superuser* credential, because a backup dumps the whole server
            # rather than one database — so this consumer claims no role, which is
            # the other half of the collection story: not every consumer of
            # DATABASE contributes to it.
            #
            # The path, never the secret: `db.superuserPassword` is deferred and
            # would be an eval error here. systemd reads the file as root before
            # dropping to the dynamic user, which is why 0600-owned-by-postgres is
            # readable.
            LoadCredential = "dbpw:${db.superuserPasswordFile}";

            # And it is actually read. `$CREDENTIALS_DIRECTORY` is where systemd
            # put it; pg_dump takes the password from PGPASSWORD. This is the whole
            # chain closed: postgres writes the file, systemd carries it, pg_dump
            # consumes it, and no floe ever held the secret at eval time.
            ExecStart =
              "/run/current-system/sw/bin/sh -c '"
              + "PGPASSWORD=$(cat \"$CREDENTIALS_DIRECTORY/dbpw\") "
              + "/run/current-system/sw/bin/pg_dumpall -h ${db.host} -p ${toString db.port}"
              + "'";
          };
        };
        timers.${inst} = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = inputs.startAt;
            Persistent = "true";
          };
        };
      };
    };
}

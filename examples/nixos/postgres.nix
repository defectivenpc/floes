# Postgres, and the thing stock NixOS cannot do at all: more than one of it.
#
# `services.postgresql` is a singleton option path. Any floe that emits it is
# single-instance no matter what the linker permits — two instances would write
# the same path and NixOS would refuse the conflicting definitions. So a
# genuinely multi-instance floe does not use that module. It emits its own
# systemd unit, its own user, its own group and its own tmpfiles rule, every one
# of them keyed by `config.floe.name` — the name the *link* gave this instance.
#
# That is the real cost of multi-instance: this file is the nixpkgs postgresql
# module's job, done again. It is also the whole benefit, and there is no
# version of it that keeps both.
#
# Note which namespaces it writes and which it does not. It writes
# `systemd.services.<unique>` and `users.users.<unique>` directly, and nothing
# owns those — because an attrset keyed by a unique name is disjoint by
# construction, so many writers cannot collide. It does *not* write
# `networking.firewall`, because a port list merges by policy rather than by
# key, and that is the kind of namespace that needs an owner.
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
  name = "postgres";
  summary = "One PostgreSQL instance, named by the link, alongside any others.";

  inputs = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "Port this instance listens on. Two instances need two ports.";
    };
    package = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw";
      description = "Prefix the server binary is found under.";
    };
  };

  provides = {
    ports = sigs.PORT_CLAIM;
    database = sigs.DATABASE;
  };

  out.nixos = kinds.nixosConfig (
    T.record {
      systemd = T.record {
        services = T.attrsOf (
          T.record {
            description = T.str;
            wantedBy = T.listOf T.str;
            serviceConfig = T.attrsOf T.str;
          }
        );
        tmpfiles = T.record { rules = T.listOf T.str; };
      };
      users = T.record {
        users = T.attrsOf (
          T.record {
            isSystemUser = T.bool;
            group = T.str;
            home = T.str;
          }
        );
        groups = T.attrsOf (T.record { });
      };
    }
  );

  modules = [
    (
      # `floe` here is the specialArg the linker injects, carrying `mkDeferred`
      # bound to this unit's name — not the library this file was passed.
      { config, floe, ... }:
      let
        # The link's name for this instance. Everything below is keyed by it, and
        # that is the only reason two of these can coexist.
        inst = config.floe.name;
        svc = "postgres-${inst}";
        dataDir = "/var/lib/${svc}";
        passwordFile = "/run/secrets/${svc}-password";
        inherit (config.floe.inputs) port package;
      in
      {
        config.floe.provides.ports.tcp = [ port ];

        config.floe.provides.database = {
          host = "127.0.0.1";
          inherit port passwordFile;

          # Generated on first start. A consumer that interpolates this into
          # NixOS config gets an eval error naming this instance as the source
          # — and with two instances, naming *which* one.
          password = floe.mkDeferred [
            "database"
            "password"
          ];
        };

        config.floe.out.nixos = {
          systemd = {
            services.${svc} = {
              description = "PostgreSQL (${inst}) on port ${toString port}";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "notify";
                User = svc;
                Group = svc;
                StateDirectory = svc;
                ExecStart = "${package}/bin/postgres -D ${dataDir} -p ${toString port}";
              };
            };
            # A list, so two instances' rules concatenate. That is correct here:
            # the rules name different directories.
            tmpfiles.rules = [ "d ${dataDir} 0700 ${svc} ${svc} - -" ];
          };

          users = {
            users.${svc} = {
              isSystemUser = true;
              group = svc;
              home = dataDir;
            };
            groups.${svc} = { };
          };
        };
      }
    )
  ];
}

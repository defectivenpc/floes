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

  # The coordination this example exists for. Postgres cannot know its consumers
  # at author time, so it collects what they ask for and provisions one role, one
  # database and one credential per claimant — at apply time, because a role
  # cannot be created before the server is running.
  collects.dbRole = sigs.DB_ROLE_CLAIM;

  provides = {
    ports = sigs.PORT_CLAIM;
    database = sigs.DATABASE;
  };

  out.nixosConfig = kinds.nixosConfig (
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

  body =
    {
      inputs,
      requires,
      collects,
      floe,
    }:
    let
      # The link's name for this instance. Everything below is keyed by it, and
      # that is the only reason two of these can coexist.
      inst = floe.name;
      svc = "postgres-${inst}";
      dataDir = "/var/lib/${svc}";
      # In the state directory, not /run: a Postgres password has to survive a
      # reboot or the stored role no longer matches. It is also per-instance, so
      # two instances never contend for one path — which `/run/secrets` shared
      # between them would have done.
      superuserPasswordFile = "${dataDir}/superuser-password";
      credentialDir = "${dataDir}/credentials";
      inherit (inputs) port package;

      # One role per claimant, named for the claiming unit. Unique in the link by
      # construction, so two workloads never contend for a role.
      claims = collects.dbRole;

      # `sh` fragments, kept as data because a floe's output must be inert.
      gen =
        f:
        "test -s ${f} || (umask 077; ${package}/bin/head -c 32 /dev/urandom | ${package}/bin/base64 > ${f})";

      # Generating every credential has to happen before the server starts, so the
      # files exist when a consumer's unit mounts them. Creating the *roles* has to
      # happen after, because that needs a running server. Two different hooks for
      # two different prerequisites, which is the shape of the real problem.
      genAll = lib.concatStringsSep " && " (
        [ (gen superuserPasswordFile) ] ++ map (u: gen "${credentialDir}/${u}") (lib.attrNames claims)
      );

      # A single-quoted SQL literal that survives the outer `sh -c '…'`. A literal
      # quote in that context is `'\''` — closing the shell quote, escaping one,
      # reopening. Writing `'${v}'` instead silently emits `PASSWORD SECRET`
      # without quotes, which is not valid SQL: `examples/shell-check.sh` catches
      # exactly that, because nothing in a Nix evaluation can.
      sq = v: "'\\''" + v + "'\\''";

      provisionAll = lib.concatMapStringsSep " && " (
        u:
        let
          db = claims.${u}.database;
          pw = "$(${package}/bin/cat ${credentialDir}/${u})";
        in
        # Idempotent, because a restart must not fail and must not rotate a
        # password a consumer is already using.
        "${package}/bin/psql -p ${toString port} -c "
        + "\"SELECT 1 FROM pg_roles WHERE rolname=${sq u}\" | ${package}/bin/grep -q 1 || "
        + "${package}/bin/psql -p ${toString port} -c "
        + "\"CREATE ROLE ${u} LOGIN PASSWORD ${sq pw}\" && "
        + "${package}/bin/psql -p ${toString port} -c "
        + "\"SELECT 1 FROM pg_database WHERE datname=${sq db}\" | ${package}/bin/grep -q 1 || "
        + "${package}/bin/psql -p ${toString port} -c \"CREATE DATABASE ${db} OWNER ${u}\""
      ) (lib.attrNames claims);
    in
    {
      provides.ports.tcp = [ port ];

      provides.database = {
        host = "127.0.0.1";
        inherit port credentialDir superuserPasswordFile;

        # Note what is *not* here: a per-consumer password. A provide is one value
        # for every consumer, so a per-claimant secret would have to be a map keyed
        # by unit — and that map is derived from the DB_ROLE_CLAIM collection, so a
        # claimant reading it is a cycle through the fold. `credentialDir` plus the
        # consumer's own name is what is left, and it needs no backend at all.
        #
        # There is a second, sharper reason it cannot work: `mkDeferred` binds
        # `source` to the unit whose body calls it, so only a *provider* can mint a
        # token for its own value. A consumer cannot construct one pointing at its
        # provider, which is correct — provenance would otherwise be a claim the
        # claimant makes about someone else.
        #
        # So the superuser credential is the one that gets both halves:
        # `superuserPasswordFile` for a consumer that passes it to a process, and
        # the deferred value for one that must render it somewhere a credential
        # cannot reach. The retrieval says where a backend would read it.
        superuserPassword = floe.mkDeferred sigs.FILE_REF {
          path = superuserPasswordFile;
          mode = "firstLine";
        };
      };

      out.nixosConfig = {
        systemd = {
          services.${svc} = {
            description = "PostgreSQL (${inst}) on port ${toString port}";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "notify";
              User = svc;
              Group = svc;
              StateDirectory = svc;

              # Every credential, before the server starts, so the files exist when
              # a consumer's unit mounts them. 0600 and idempotent: a restart must
              # not rotate a password a consumer is already using.
              #
              # In a real system this is where sops-nix or systemd-creds would go.
              # The point for the example is that *something* in the link writes
              # the file a consumer's LoadCredential reads, and a test asserts
              # those two paths are the same string.
              ExecStartPre = "${package}/bin/sh -c '${genAll}'";

              ExecStart = "${package}/bin/postgres -D ${dataDir} -p ${toString port}";

              # And the roles, after — a role cannot be created before the server
              # accepts connections. This is the half that needed the collection:
              # postgres learned what to provision from its peers, and no deployer
              # wrote a role name anywhere.
              # A plain conditional and not `lib.mkIf`: a `body` returns data, and
              # the module system is not here to discharge a property wrapper.
            }
            // lib.optionalAttrs (claims != { }) {
              ExecStartPost = "${package}/bin/sh -c '${provisionAll}'";
            };
          };
          # A list, so two instances' rules concatenate. That is correct here:
          # the rules name different directories.
          tmpfiles.rules = [
            "d ${dataDir} 0700 ${svc} ${svc} - -"
            "d ${credentialDir} 0700 ${svc} ${svc} - -"
          ];
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
    };
}

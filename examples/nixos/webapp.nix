# The workload. Notice what it does *not* provide: no PORT_CLAIM, because it
# listens on loopback and nginx is what the world talks to. A floe contributes
# to the namespaces it actually touches and stays out of the rest — in stock
# NixOS there is no way to tell, because opening a port and not opening one
# look the same from outside the module.
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
  name = "webapp";
  summary = "A small HTTP service behind the proxy, talking to the database.";

  inputs = {
    subdomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Hostname to claim, under the proxy's base domain. Null means use the
        link's name for this instance, which is unique by construction — so
        twenty workloads need twenty names and the deployer writes none of them.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port to listen on.";
    };
  };

  requires = {
    database = sigs.DATABASE;
    proxy = sigs.REVERSE_PROXY;
  };

  provides = {
    route = sigs.ROUTE_CLAIM;
    scrape = sigs.SCRAPE_TARGET;
    # Asks the database for a role of its own. Postgres collects these and
    # provisions one role, one database and one credential per claimant — so no
    # deployer writes a role name, and twenty workloads get twenty credentials.
    dbRole = sigs.DB_ROLE_CLAIM;
  };

  out.nixosConfig = kinds.nixosConfig (
    T.record {
      systemd = T.record {
        services = T.attrsOf (
          T.record {
            description = T.str;
            wantedBy = T.listOf T.str;
            after = T.listOf T.str;
            environment = T.attrsOf T.str;
            serviceConfig = T.attrsOf T.str;
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
      db = requires.database;
      proxy = requires.proxy;
      inherit (inputs) port;

      # Keyed by the link's name for this instance, so twenty of these coexist
      # instead of twenty definitions of one unit.
      inst = floe.name;
      subdomain = if inputs.subdomain == null then inst else inputs.subdomain;
      host = "${subdomain}.${proxy.baseDomain}";
    in
    {
      provides.route = { inherit subdomain port; };

      # One database per workload, named for it. The role postgres creates is this
      # unit's name, so neither is a string a deployer had to invent or keep
      # unique.
      provides.dbRole.database = inst;

      provides.scrape = {
        inherit port;
        path = "/metrics";
      };

      out.nixosConfig.systemd.services.${inst} = {
        description = "Workload ${inst} at ${host}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        environment = {
          # `db.password` would be an eval error here: it is deferred, and a
          # systemd environment value is a string. The *path* is what a unit can
          # be given at eval, and the secret arrives at start — which is why this
          # URL carries no credential.
          # The role and the database are both this unit's name, which is what
          # was claimed. No string the signature did not promise.
          DATABASE_URL = "postgresql://${inst}@${db.host}:${toString db.port}/${inst}";
          PUBLIC_URL = "${proxy.scheme}://${host}";
          LISTEN_PORT = toString port;
        };

        serviceConfig = {
          DynamicUser = "true";

          # This workload's *own* credential, at the directory the signature
          # promised joined with the name it already knows. Not a shared secret:
          # twenty workloads read twenty files.
          #
          # systemd reads it as root — before dropping to the dynamic user — so a
          # 0600 file owned by the postgres instance is still readable here.
          LoadCredential = "dbpw:${db.credentialDir}/${inst}";

          # And it is read, where the password is actually needed. The secret
          # never appears in the unit, the environment, or the Nix store: the only
          # thing eval ever saw was a path.
          ExecStart =
            "/run/current-system/sw/bin/sh -c '"
            + ''PGPASSWORD=$(cat "$CREDENTIALS_DIRECTORY/dbpw") ''
            + "exec /run/current-system/sw/bin/webapp'";
        };
      };
    };
}

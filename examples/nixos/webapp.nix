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
  };

  out.nixos = kinds.nixosConfig (
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

  modules = [
    (
      { config, ... }:
      let
        db = config.floe.requires.database;
        proxy = config.floe.requires.proxy;
        inherit (config.floe.inputs) port;

        # Keyed by the link's name for this instance, so twenty of these coexist
        # instead of twenty definitions of one unit.
        inst = config.floe.name;
        subdomain = if config.floe.inputs.subdomain == null then inst else config.floe.inputs.subdomain;
        host = "${subdomain}.${proxy.baseDomain}";
      in
      {
        config.floe.provides.route = { inherit subdomain port; };
        config.floe.provides.scrape = {
          inherit port;
          path = "/metrics";
        };

        config.floe.out.nixos.systemd.services.${inst} = {
          description = "Workload ${inst} at ${host}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          environment = {
            # `db.password` would be an eval error here: it is deferred, and a
            # systemd environment value is a string. The *path* is what a unit
            # can be given at eval, and the secret arrives at start.
            DATABASE_URL = "postgresql://${db.host}:${toString db.port}/webapp";
            PUBLIC_URL = "${proxy.scheme}://${host}";
            LISTEN_PORT = toString port;
          };

          serviceConfig = {
            DynamicUser = "true";
            LoadCredential = "dbpw:${db.passwordFile}";
            ExecStart = "/usr/bin/env webapp";
          };
        };
      }
    )
  ];
}

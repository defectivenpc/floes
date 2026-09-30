# nginx: a service that plays both roles at once.
#
# It *contributes* to a namespace it does not own (a PORT_CLAIM, which
# `networking` merges), and it *collects* from its own peers (a ROUTE_CLAIM
# from every workload that wants a hostname). One mechanism, both directions.
#
# It also closes the cycle the whole design has to survive: nginx requires
# NETWORK, and networking collects nginx's PORT_CLAIM. Under stock NixOS
# laziness that is fine, and it is fine here, because nginx reads `domain` —
# which comes from networking's inputs, not from the collection. Read
# `openPorts` instead and it recurses; see `tests/support/failures.nix`.
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
  name = "nginx";
  summary = "Reverse proxy, routing whatever hostnames its peers claim.";

  requires.network = sigs.NETWORK;
  collects.routes = sigs.ROUTE_CLAIM;

  provides = {
    ports = sigs.PORT_CLAIM;
    proxy = sigs.REVERSE_PROXY;
  };

  out.nixos = kinds.nixosConfig (
    T.record {
      services = T.record {
        nginx = T.record {
          enable = T.bool;
          recommendedProxySettings = T.bool;
          virtualHosts = T.attrsOf (
            T.record {
              locations = T.attrsOf (T.record { proxyPass = T.url; });
            }
          );
        };
      };
    }
  );

  modules = [
    (
      { config, ... }:
      let
        # `domain` only. Reading `config.floe.requires.network.openPorts` here
        # would be a cycle through this floe's own contribution.
        inherit (config.floe.requires.network) domain;

        routes = config.floe.collects.routes;
      in
      {
        config.floe.provides.ports.tcp = [
          80
          443
        ];

        config.floe.provides.proxy = {
          baseDomain = domain;
          # Plain http: a contrived example that turned on ACME would need a
          # real account and a reachable name, and would stop being contrived.
          scheme = "http";
        };

        config.floe.out.nixos.services.nginx = {
          enable = true;
          recommendedProxySettings = true;
          virtualHosts = lib.mapAttrs' (
            _unit: route:
            lib.nameValuePair "${route.subdomain}.${domain}" {
              locations."/".proxyPass = "http://127.0.0.1:${toString route.port}";
            }
          ) routes;
        };
      }
    )
  ];
}

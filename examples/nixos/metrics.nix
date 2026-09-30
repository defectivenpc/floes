# A second collector, so the example has more than one.
#
# `networking` collects PORT_CLAIMs because a port list merges by policy.
# This collects SCRAPE_TARGETs for a different reason: it needs to *enumerate*
# its peers, and there is no other way to learn who exists. In the fleet link it
# ends up with twenty members.
#
# Its merge is not a union or a conflict check — it is a fold into one config
# file's scrape stanzas, keyed by the unit that asked. Nothing here has to know
# which workloads exist, and adding one does not touch this file.
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
  name = "metrics";
  summary = "Prometheus, scraping whichever peers asked to be scraped.";

  # Writes fixed paths, so two of it would silently merge into one.
  singleton = true;

  inputs.interval = lib.mkOption {
    type = lib.types.str;
    default = "30s";
    description = "Scrape interval.";
  };

  requires.network = sigs.NETWORK;
  collects.targets = sigs.SCRAPE_TARGET;
  provides.ports = sigs.PORT_CLAIM;

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
      };
      environment = T.record {
        etc = T.attrsOf (T.record { text = T.str; });
      };
    }
  );

  modules = [
    (
      { config, ... }:
      let
        targets = config.floe.collects.targets;
        inherit (config.floe.requires.network) hostName;
        inherit (config.floe.inputs) interval;

        stanza = unit: t: ''
          - job_name: ${unit}
            scrape_interval: ${interval}
            metrics_path: ${t.path}
            static_configs:
              - targets: [ "127.0.0.1:${toString t.port}" ]
        '';
      in
      {
        config.floe.provides.ports.tcp = [ 9090 ];

        config.floe.out.nixos = {
          systemd.services.prometheus = {
            description = "Prometheus on ${hostName}, ${toString (lib.length (lib.attrNames targets))} target(s)";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              DynamicUser = "true";
              ExecStart = "/run/current-system/sw/bin/prometheus --config.file=/etc/prometheus.yml";
            };
          };

          environment.etc."prometheus.yml".text = ''
            scrape_configs:
            ${lib.concatStrings (lib.mapAttrsToList stanza targets)}
          '';
        };
      }
    )
  ];
}

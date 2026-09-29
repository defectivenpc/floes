# Wraps the grafana chart. Demonstrates inputs with and without defaults, an
# exactly-one hole (ingress), a collection (dashboards), providing OBSERVER,
# and consuming a deferred value in out.k8s.
{
  lib,
  floe,
  sigs,
  kinds,
}:

floe.mkFloe {
  name = "grafana";
  summary = "Fixture floe for a test suite.";

  inputs = {
    size = lib.mkOption {
      type = lib.types.str;
      default = "10Gi";
      description = "PVC size for Grafana storage.";
    };
    adminUser = lib.mkOption {
      type = lib.types.str;
      description = "Initial admin username. Required.";
    };
  };

  requires.ingress = sigs.INGRESS;
  collects.dashboards = sigs.DASHBOARD_REQ;
  provides.observer = sigs.OBSERVER;
  out = {
    k8s = kinds.k8s;
    meta = kinds.meta;
  };

  modules = [
    (
      { config, lib, ... }:
      let
        ingress = config.floe.requires.ingress;
        host = "grafana.${ingress.baseDomain}";
        # Every DASHBOARD_REQ in the link, keyed by the unit asking.
        requested = config.floe.collects.dashboards;
      in
      {
        config.floe.provides.observer = {
          ingressUrl = "https://${host}";
          dashboards = lib.mapAttrs' (
            _unit: req: lib.nameValuePair req.app { url = "https://${host}/d/app-${req.app}"; }
          ) requested;
        };

        config.floe.out.k8s.helmRelease = {
          chart = "grafana/grafana";
          version = "8.5.1";
          values = {
            adminUser = config.floe.inputs.adminUser;
            persistence.size = config.floe.inputs.size;
            ingress = {
              enabled = true;
              hosts = [ host ];
              ingressClassName = ingress.className;
            };
            # Deferred token flows into output data; the linker's scan turns
            # this into a deploy edge grafana -> nginx-ingress and a phase.
            annotations."floe.dev/lb-address" = ingress.address;
          };
        };

        config.floe.out.meta = {
          cluster = "observability";
          environment = "lab";
        };
      }
    )
  ];
}

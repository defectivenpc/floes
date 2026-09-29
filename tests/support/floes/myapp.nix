# Consumes OBSERVER without knowing it is grafana, and provides its own
# DASHBOARD_REQ, which grafana collects. The mutual reference resolves
# lazily: neither provide's fields depend on the other's.
{
  floe,
  sigs,
  kinds,
  lib,
}:

floe.mkFloe {
  name = "myapp";
  summary = "Fixture floe for a test suite.";

  inputs.app = lib.mkOption {
    type = lib.types.str;
    default = "myapp";
    description = "Name this instance asks for a dashboard under.";
  };

  requires.observer = sigs.OBSERVER;
  provides.dashboardReq = sigs.DASHBOARD_REQ;
  out = {
    k8s = kinds.k8s;
    meta = kinds.meta;
  };

  modules = [
    (
      { config, ... }:
      let
        app = config.floe.inputs.app;
      in
      {
        config.floe.provides.dashboardReq = {
          inherit app;
          panels = [
            "http_requests_total"
            "latency_p99"
          ];
        };

        config.floe.out.k8s.deployment = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = app;
            annotations."runbook/dashboard" = config.floe.requires.observer.dashboards.${app}.url;
          };
        };

        config.floe.out.meta = {
          cluster = "internal";
          environment = "lab";
        };
      }
    )
  ];
}

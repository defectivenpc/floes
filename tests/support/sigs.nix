# Domain signatures for the example deployment.
{ floe }:

let
  # A pretend distribution, so it extends the prelude the way a real one does
  # rather than expecting core to carry its domain's types.
  T = floe.T // {
    k8sName = floe.T.str;
  };
in
{
  INGRESS = floe.mkSig {
    name = "INGRESS";
    as = "ingress";
    description = "Fixture: an ingress with a base domain and an assigned address.";
    fields = {
      baseDomain = T.dnsName;
      className = T.str;
      # Only exists after apply; typed as deferred so eval-time misuse is an error.
      address = T.deferred T.str;
    };
  };

  OBSERVER = floe.mkSig {
    name = "OBSERVER";
    as = "observer";
    description = "Fixture: something that collects dashboards from its peers.";
    fields = {
      ingressUrl = T.url;
      dashboards = T.attrsOf (T.record { url = T.url; });
    };
  };

  DASHBOARD_REQ = floe.mkSig {
    name = "DASHBOARD_REQ";
    as = "dashboard";
    description = "Fixture: a dashboard a workload asks an observer to render.";
    fields = {
      app = T.k8sName;
      panels = T.listOf T.str;
    };
  };
}

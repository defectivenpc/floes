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
  # A retrieval signature: where a value will be readable once it exists.
  STATUS_FIELD = floe.mkSig {
    name = "k8s.statusField";
    canonicalName = "statusField";
    description = "Fixture: readable from a field of a resource's status, once applied.";
    shape = T.record {
      resource = T.str;
      field = T.str;
    };
  };

  INGRESS = floe.mkSig {
    name = "INGRESS";
    canonicalName = "ingress";
    description = "Fixture: an ingress with a base domain and an assigned address.";
    shape = T.record {
      baseDomain = T.dnsName;
      className = T.str;
      # Only exists after apply; typed as runtime so eval-time misuse is an error.
      address = T.runtime T.str;
    };
  };

  OBSERVER = floe.mkSig {
    name = "OBSERVER";
    canonicalName = "observer";
    description = "Fixture: something that collects dashboards from its peers.";
    shape = T.record {
      ingressUrl = T.url;
      dashboards = T.attrsOf (T.record { url = T.url; });
    };
  };

  DASHBOARD_REQ = floe.mkSig {
    name = "DASHBOARD_REQ";
    canonicalName = "dashboard";
    description = "Fixture: a dashboard a workload asks an observer to render.";
    shape = T.record {
      app = T.k8sName;
      panels = T.listOf T.str;
    };
  };
}

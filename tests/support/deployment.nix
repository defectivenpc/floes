# A four-unit deployment: ingress, grafana, and two apps.
# Both apps are one floe instantiated twice and both provide DASHBOARD_REQ,
# so grafana's collection has more than one member.
{
  lib,
  floe,
  floes,
  policies,
}:

floe.link {
  units = {
    ingress = floes.nginxIngress.instantiate {
      baseDomain = "lab.example.com";
    };
    grafana = floes.grafana.instantiate {
      size = "50Gi";
      adminUser = "michael";
    };
    myapp = floes.myapp.instantiate { };
    billing = floes.myapp.instantiate { app = "billing"; };
  };
  policies = [ policies.noEnvMixing ];
}

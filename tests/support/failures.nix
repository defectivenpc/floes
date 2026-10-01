# Each attribute here throws when evaluated, one error class each:
#
#   nix eval .#example.failures.missingInput
{
  lib,
  floe,
  sigs,
  kinds,
  floes,
  policies,
}:

let
  ingressUnit = floes.nginxIngress.instantiate { baseDomain = "lab.example.com"; };
in
{
  # instantiate-time input errors (module system messages, floe context)
  missingInput = (floes.grafana.instantiate { size = "50Gi"; }).inputsChecked;

  unknownInput =
    (floes.grafana.instantiate {
      adminUser = "michael";
      sizes = "50Gi"; # typo
    }).inputsChecked;

  wrongInputType =
    (floes.grafana.instantiate {
      adminUser = "michael";
      size = 50; # int, not string
    }).inputsChecked;

  # link-time coherence error
  missingProvider =
    (floe.link {
      units = {
        grafana = floes.grafana.instantiate { adminUser = "michael"; };
        myapp = floes.myapp.instantiate { };
      };
    }).graph;

  # seal-time signature violation: bad URL shape in a provide
  badProvideShape =
    let
      broken = floe.mkFloe {
        name = "broken-observer";
        summary = "Fixture floe for a test suite.";
        provides.observer = sigs.OBSERVER;
        modules = [
          {
            config.floe.provides.observer = {
              ingressUrl = "grafana.example.com"; # missing scheme
              dashboards = { };
            };
          }
        ];
      };
    in
    (floe.link {
      units = {
        observer = broken.instantiate { };
        myapp = floes.myapp.instantiate { };
      };
    }).provides.observer.observer;

  # deferred misuse: a post-apply value where a concrete url is required
  deferredMisuse =
    let
      impatient = floe.mkFloe {
        name = "impatient";
        summary = "Fixture floe for a test suite.";
        requires.ingress = sigs.INGRESS;
        provides.observer = sigs.OBSERVER;
        modules = [
          ({ config, ... }: {
            config.floe.provides.observer = {
              # address only exists post-apply; OBSERVER.ingressUrl is concrete
              ingressUrl = config.floe.requires.ingress.address;
              dashboards = { };
            };
          })
        ];
      };
    in
    (floe.link {
      units = {
        ingress = ingressUnit;
        obs = impatient.instantiate { };
      };
    }).provides.obs.observer.ingressUrl;

  # deferred-value cycle: each side's output waits on a value the other only
  # has after apply, so no phase can be assigned to either.
  deferredCycle =
    let
      loopSig =
        n:
        floe.mkSig {
          name = "LOOP_${n}";
          canonicalName = "loop${n}";
          description = "Fixture: a post-apply address, one half of a cycle.";
          shape = floe.T.record { address = floe.T.deferred floe.T.str; };
        };

      a = loopSig "A";
      b = loopSig "B";

      mk =
        {
          name,
          mine,
          peer,
        }:
        floe.mkFloe {
          inherit name;
          summary = "Fixture floe for a test suite.";
          requires.peer = peer;
          provides.mine = mine;
          out.k8s = kinds.k8s;
          modules = [
            (
              { config, floe, ... }:
              {
                config.floe.provides.mine.address = floe.mkDeferred sigs.STATUS_FIELD {
                  resource = "service/${name}";
                  field = "status.addr";
                };
                config.floe.out.k8s.waiter.metadata.annotations.peer = config.floe.requires.peer.address;
              }
            )
          ];
        };
    in
    (floe.link {
      units = {
        loop-a =
          (mk {
            name = "loop-a";
            mine = a;
            peer = b;
          }).instantiate
            { };
        loop-b =
          (mk {
            name = "loop-b";
            mine = b;
            peer = a;
          }).instantiate
            { };
      };
    }).phases;

  # policy violation: a prod unit linked into a lab graph
  policyViolation =
    let
      prodApp = floe.mkFloe {
        name = "prod-app";
        summary = "Fixture floe for a test suite.";
        requires.observer = sigs.OBSERVER;
        provides.dashboardReq = sigs.DASHBOARD_REQ;
        out = {
          meta = kinds.meta;
        };
        modules = [
          {
            config.floe.provides.dashboardReq = {
              app = "prod-app";
              panels = [ ];
            };
            config.floe.out.meta = {
              cluster = "internal";
              environment = "prod";
            };
          }
        ];
      };
    in
    (floe.link {
      units = {
        ingress = ingressUnit;
        grafana = floes.grafana.instantiate { adminUser = "michael"; };
        myapp = prodApp.instantiate { };
      };
      policies = [ policies.noEnvMixing ];
    }).graph;
}

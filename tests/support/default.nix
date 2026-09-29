{ lib, floe }:

let
  sigs = import ./sigs.nix { inherit floe; };
  kinds = import ./kinds.nix { inherit floe; };
  policies = import ./policies.nix { inherit lib; };

  floes = {
    nginxIngress = import ./floes/nginx-ingress.nix {
      inherit
        lib
        floe
        sigs
        kinds
        ;
    };
    grafana = import ./floes/grafana.nix {
      inherit
        lib
        floe
        sigs
        kinds
        ;
    };
    myapp = import ./floes/myapp.nix {
      inherit
        lib
        floe
        sigs
        kinds
        ;
    };
  };

  deployment = import ./deployment.nix {
    inherit
      lib
      floe
      floes
      policies
      ;
  };
in
{
  inherit
    sigs
    kinds
    floes
    deployment
    ;

  # JSON-friendly view of the link result.
  summary = {
    inherit (deployment) graph phases provides;
    outKinds = lib.attrNames deployment.out;
  };

  manifests = deployment.out."k8s.manifests";
  meta = deployment.out."catallaxy.meta";

  failures = import ./failures.nix {
    inherit
      lib
      floe
      sigs
      kinds
      floes
      policies
      ;
  };
}

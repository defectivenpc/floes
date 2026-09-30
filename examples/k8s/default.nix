# A Kubernetes distribution.
{ lib, floe }:

let
  T = floe.T;

  sigs = {
    CLUSTER = floe.mkSig {
      name = "CLUSTER";
      as = "cluster";
      description = "A Kubernetes cluster to install into.";
      fields = {
        version = T.str;
        # Link-local: a cluster's API endpoint means nothing in another link,
        # so a consumer elsewhere is refused this field rather than handed a
        # value that points at the wrong place.
        apiServer = T.local T.url;
      };
    };

    ISSUER = floe.mkSig {
      name = "ISSUER";
      as = "issuer";
      description = "Something that can sign certificates in this cluster.";
      fields = {
        name = T.str;
        # Not known until cert-manager has generated its CA.
        caFingerprint = T.deferred T.str;
      };
    };
  };

  # One loose kind, shared. See the header: a manifest has no shape worth
  # declaring
  manifests = floe.mkOutputKind {
    name = "k8s.manifests";
    description = "Rendered Kubernetes resources, keyed by name.";
    schema = T.attrsOf T.any;
  };

  cluster = floe.mkFloe {
    name = "cluster";
    summary = "The cluster itself: what everything else installs into.";

    inputs.version = lib.mkOption {
      type = lib.types.str;
      default = "1.31";
      description = "Kubernetes minor version.";
    };

    provides.cluster = sigs.CLUSTER;

    modules = [
      (
        { config, ... }:
        {
          config.floe.provides.cluster = {
            inherit (config.floe.inputs) version;
            apiServer = "https://api.cluster.internal:6443";
          };
        }
      )
    ];
  };

  certManager = floe.mkFloe {
    name = "cert-manager";
    summary = "cert-manager, with a self-signed cluster issuer.";

    requires.cluster = sigs.CLUSTER;
    provides.issuer = sigs.ISSUER;
    out.k8s = manifests;

    modules = [
      (
        { config, floe, ... }:
        {
          config.floe.provides.issuer = {
            name = "cluster-ca";
            caFingerprint = floe.mkDeferred [
              "issuer"
              "caFingerprint"
            ];
          };

          config.floe.out.k8s.helmRelease = {
            chart = "jetstack/cert-manager";
            version = "1.16.2";
            values.installCRDs = true;
          };
        }
      )
    ];
  };

  podinfo = floe.mkFloe {
    name = "podinfo";
    summary = "A small workload, pinned to the cluster's issuer.";

    requires = {
      cluster = sigs.CLUSTER;
      issuer = sigs.ISSUER;
    };
    out.k8s = manifests;

    modules = [
      (
        { config, ... }:
        let
          issuer = config.floe.requires.issuer;
        in
        {
          config.floe.out.k8s.certificate = {
            issuerRef.name = issuer.name;
            # The deferred token in output data is what the linker scans for,
            # and it is why podinfo lands in a later phase than cert-manager.
            annotations."floe.dev/ca-fingerprint" = issuer.caFingerprint;
          };
        }
      )
    ];
  };

  floes = { inherit cluster certManager podinfo; };

  link = floe.link {
    units = {
      cluster = cluster.instantiate { };
      cert-manager = certManager.instantiate { };
      podinfo = podinfo.instantiate { };
    };
  };
in
{
  inherit
    sigs
    floes
    link
    ;
  manifests = link.out."k8s.manifests";
}

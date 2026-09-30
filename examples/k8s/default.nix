# A Kubernetes distribution.
{ lib, floe }:

let
  T = floe.T;

  sigs = {
    CLUSTER = floe.mkSig {
      name = "CLUSTER";
      canonicalName = "cluster";
      description = "A Kubernetes cluster to install into.";
      shape = T.record {
        version = T.str;
        apiServer = T.url;
      };
    };

    ISSUER = floe.mkSig {
      name = "ISSUER";
      canonicalName = "issuer";
      description = "Something that can sign certificates in this cluster.";
      shape = T.record {
        name = T.str;
        # Not known until cert-manager has generated its CA.
        caFingerprint = T.runtime T.str;
      };
    };
  };

  # One loose kind, shared. See the header: a manifest has no shape worth
  # declaring
  manifests = floe.mkSig {
    name = "k8s.manifests";
    canonicalName = "k8s";
    description = "Rendered Kubernetes resources, keyed by name.";
    shape = T.attrsOf T.any;
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

    body =
      { inputs, ... }:
      {
        provides.cluster = {
          inherit (inputs) version;
          apiServer = "https://api.cluster.internal:6443";
        };
      };
  };

  certManager = floe.mkFloe {
    name = "cert-manager";
    summary = "cert-manager, with a self-signed cluster issuer.";

    requires.cluster = sigs.CLUSTER;
    provides.issuer = sigs.ISSUER;
    out.k8s = manifests;

    body =
      { floe, ... }:
      {
        provides.issuer = {
          name = "cluster-ca";
          caFingerprint = floe.mkRuntime [
            "issuer"
            "caFingerprint"
          ];
        };

        out.k8s.helmRelease = {
          chart = "jetstack/cert-manager";
          version = "1.16.2";
          values.installCRDs = true;
        };
      };
  };

  podinfo = floe.mkFloe {
    name = "podinfo";
    summary = "A small workload, pinned to the cluster's issuer.";

    requires = {
      cluster = sigs.CLUSTER;
      issuer = sigs.ISSUER;
    };
    out.k8s = manifests;

    body =
      { requires, ... }:
      {
        out.k8s.certificate = {
          issuerRef.name = requires.issuer.name;
          # The runtime token in output data is what the linker scans for, and
          # it is why podinfo lands in a later phase than cert-manager.
          annotations."floe.dev/ca-fingerprint" = requires.issuer.caFingerprint;
        };
      };
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

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

    # A retrieval signature: where a value will be readable once it exists, not
    # what it is. Core checks a ref against this shape and records the name; it
    # never learns what a Secret is. A backend implements the reading, and there
    # may be several — one that uses the API, one that shells out to kubectl.
    SECRET_REF = floe.mkSig {
      name = "k8s.secretRef";
      canonicalName = "secretRef";
      description = "Readable from a key of a Kubernetes Secret, once applied.";
      shape = T.record {
        namespace = T.str;
        name = T.str;
        key = T.str;
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
          # cert-manager knows where its CA lands, because cert-manager is what
          # puts it there. The consumer never learns this — it reads
          # `issuer.caFingerprint` and a backend fills it in.
          caFingerprint = floe.mkRuntime sigs.SECRET_REF {
            namespace = "cert-manager";
            name = "cluster-ca-tls";
            key = "ca.crt";
          };
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

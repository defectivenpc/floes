# A Kubernetes distribution, in one file, on purpose.
#
# This example exists for the contrast with `examples/nixos`. Same library,
# same four mechanisms, and a completely different shape:
#
#                      nixos                     k8s
#   unit               a systemd service         a Helm chart
#   floes              5                         3
#   signatures         5                         2
#   collected          2 (PORT_CLAIM, ROUTE)     0
#   eval cycles        2, both mutual            0, a chain
#   output typing      narrow, per floe          loose, shared
#
# The last two rows are the interesting ones. Kubernetes components have clean
# boundaries and coarse grain, so nothing needs a collection and nothing points
# backwards — resolution is a chain and the graph is a tree. And a rendered
# manifest is opaque by nature, so there is no useful `T.record` to write for
# it; floe does not insist on one.
#
# Floe was designed against this shape. `examples/nixos` is the harder case,
# and the reason the library needed testing against a second domain at all.
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
        # Not known until cert-manager has generated its CA. A floe that
        # renders it into a manifest gets a deploy edge and a later phase, not
        # an eval error — a manifest is data that ships after apply.
        caFingerprint = T.deferred T.str;
      };
    };
  };

  # One loose kind, shared. See the header: a manifest has no shape worth
  # declaring, and `examples/nixos/kinds.nix` is where the narrow case lives.
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

# A Kubernetes distribution.
{ lib, floe }:

let
  T = floe.T;

  sigs = {
    CLUSTER = floe.mkSig {
      name = "CLUSTER";
      canonicalName = "cluster";
      description = "A Kubernetes cluster to install into.";
      fields = {
        version = T.str;
        apiServer = T.url;
      };
    };

    # A retrieval signature: where a value will be readable once it exists, not
    # what it is. Core checks a ref against this shape and records the name; it
    # never learns what a Secret is. A backend implements the reading, and there
    # may be several: one that uses the API, one that shells out to kubectl.
    SECRET_REF = floe.mkSig {
      name = "k8s.secretRef";
      canonicalName = "secretRef";
      description = "Readable from a key of a Kubernetes Secret, once applied.";
      fields = {
        namespace = T.str;
        name = T.str;
        key = T.str;
      };
    };

    ISSUER = floe.mkSig {
      name = "ISSUER";
      canonicalName = "issuer";
      description = "Something that can sign certificates in this cluster.";
      fields = {
        name = T.str;
        # Not known until cert-manager has generated its CA.
        caFingerprint = T.deferred T.str;
      };
    };

    # The export signature for a cluster held by a lab, and the whole of what
    # replaces `T.local`. `CLUSTER` carries `apiServer`, an address that means
    # something only inside the cluster it describes; this does not carry it, so
    # the lab cannot read it. The boundary declares what crosses and sealing
    # drops the rest, instead of every field carrying a locality marking for a
    # boundary most of them never meet.
    CLUSTER_SUMMARY = floe.mkSig {
      name = "CLUSTER_SUMMARY";
      canonicalName = "clusterSummary";
      description = "What a lab knows about one of its clusters.";
      fields = {
        version = T.str;
      };
    };
  };

  # One loose kind, shared. See the header: a manifest has no shape worth
  # declaring
  manifests = floe.mkSig {
    name = "k8s.manifests";
    canonicalName = "k8s";
    description = "Rendered Kubernetes resources, keyed by name.";
    fields = T.attrsOf T.any;
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
          # puts it there. The consumer never learns this: it reads
          # `issuer.caFingerprint` and a backend fills it in.
          caFingerprint = floe.mkDeferred sigs.SECRET_REF {
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
          # The deferred token in output data is what the linker scans for, and
          # it is why podinfo lands in a later phase than cert-manager.
          annotations."floe.dev/ca-fingerprint" = requires.issuer.caFingerprint;
        };
      };
  };

  # ---- A lab holding clusters ---------------------------------------------
  #
  # The second link, and the one that answers `docs/adr/0003`'s condition for
  # `scope` coming back: a worked multi-link example rather than a request.
  # Nothing new is linking here: an inclusion is a floe whose body is a link,
  # so the lab resolves it by the rules it resolves anything by.

  labCa = floe.mkFloe {
    name = "lab-ca";
    summary = "The lab's trust root, held outside any cluster.";

    provides.issuer = sigs.ISSUER;
    out.k8s = manifests;

    body =
      { floe, ... }:
      {
        provides.issuer = {
          name = "lab-ca";
          caFingerprint = floe.mkDeferred sigs.SECRET_REF {
            namespace = "lab";
            name = "lab-ca-tls";
            key = "ca.crt";
          };
        };
        out.k8s.secret.metadata.name = "lab-ca-tls";
      };
  };

  # One cluster and what runs in it, as a unit of the lab.
  #
  # `requires.issuer` is left *open*: nothing inside answers it, and the parent
  # does. That is the half of inclusion worth having, because a cluster with an
  # open hole is reusable across labs, and a lab can supply its clusters rather
  # than only reading from them.
  #
  # It also *defines*, which is the other half: `units` includes a link and
  # `body` emits a fragment of its own, the namespace the workloads inside live
  # in. MixML says a unit that includes may also define, and this is where the
  # library takes it at its word. The two outputs cannot collide, because the
  # inner units land under `app/cluster` and this one lands under `app`.
  #
  # `floe.name` keys the namespace, so two instances of this floe are two
  # namespaces rather than one merged one, exactly as a multi-instance floe
  # keys any other output.
  clusterEnv = floe.mkFloe {
    name = "cluster-env";
    summary = "One cluster and the workloads in it, linked as a unit.";

    inputs.version = lib.mkOption {
      type = lib.types.str;
      default = "1.31";
      description = "Kubernetes minor version for this cluster.";
    };

    requires.issuer = sigs.ISSUER;

    provides.clusterSummary = sigs.CLUSTER_SUMMARY;
    exports.clusterSummary = "cluster";

    out.k8s = manifests;

    units =
      { inputs, ... }:
      {
        cluster = cluster.instantiate { inherit (inputs) version; };
        podinfo = podinfo.instantiate { };
      };

    body =
      { floe, ... }:
      {
        out.k8s.namespace.metadata.name = floe.name;
      };
  };

  labReport = floe.mkFloe {
    name = "lab-report";
    summary = "One record of every cluster the lab holds.";

    collects.clusterSummary = sigs.CLUSTER_SUMMARY;
    out.k8s = manifests;

    body =
      { collects, ... }:
      {
        out.k8s.configMap.data = lib.mapAttrs (_: s: s.version) collects.clusterSummary;
      };
  };

  floes = {
    inherit
      cluster
      certManager
      podinfo
      labCa
      labReport
      ;
  };

  link = floe.link {
    units = {
      cluster = cluster.instantiate { };
      cert-manager = certManager.instantiate { };
      podinfo = podinfo.instantiate { };
    };
  };

  lab = floe.link {
    units = {
      ca = labCa.instantiate { };
      report = labReport.instantiate { };
      app = clusterEnv.instantiate { version = "1.31"; };
      web = clusterEnv.instantiate { version = "1.30"; };
    };
  };
in
{
  inherit
    sigs
    floes
    clusterEnv
    link
    lab
    ;
  manifests = link.out."k8s.manifests";
}

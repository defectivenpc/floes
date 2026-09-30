# What the example floes emit. Signatures, like everything else a floe commits
# to — there used to be a separate `mkOutputKind` for this and it was the same
# record with a different word on it.
{ floe }:

let
  T = floe.T;
in
{
  k8s = floe.mkSig {
    name = "k8s.manifests";
    canonicalName = "k8s";
    description = "Fixture: rendered manifests, for the test suite.";
    # Loose on purpose for the playground; a real one would narrow it.
    shape = T.attrsOf T.any;
  };

  meta = floe.mkSig {
    name = "catallaxy.meta";
    canonicalName = "meta";
    description = "Fixture: arbitrary metadata, for the test suite.";
    shape = T.record {
      cluster = T.enum [
        "management"
        "observability"
        "internal"
        "public"
      ];
      environment = T.enum [
        "lab"
        "prod"
      ];
    };
  };
}

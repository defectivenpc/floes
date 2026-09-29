# Output kinds for the example distribution. Floe core knows none of these.
{ floe }:

let
  T = floe.T;
in
{
  k8s = floe.mkOutputKind {
    name = "k8s.manifests";
    description = "Fixture kind: rendered manifests, for the test suite.";
    # Loose on purpose for the playground; tighten with T.record schemas later.
    schema = T.attrsOf T.any;
  };

  meta = floe.mkOutputKind {
    name = "catallaxy.meta";
    description = "Fixture kind: arbitrary metadata, for the test suite.";
    schema = T.record {
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

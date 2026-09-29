# Link-time policies: functions over the link result returning violations.
# Core owns coherence; the distribution owns domain legality.
{ lib }:

{
  # No edge may connect floes in different environments.
  noEnvMixing =
    result:
    let
      envOf = u: (result.out."catallaxy.meta".${u} or { }).environment or null;
    in
    lib.concatMap (
      e:
      let
        a = envOf e.from;
        b = envOf e.to;
      in
      lib.optional (
        a != null && b != null && a != b
      ) "environment mixing: '${e.from}' (${a}) -> '${e.to}' (${b}) via '${e.via}'"
    ) result.graph.edges;
}

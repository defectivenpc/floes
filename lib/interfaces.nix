# Signatures and output kinds. Both are pure data.
{ lib, types }:

{
  # A signature: a named schema for a value a floe commits to — one that crosses
  # to a peer (`requires`, `optional`, `collects`, `provides`) or one it emits
  # (`out`). There used to be a second constructor, `mkOutputKind`, for the
  # second case; it was the same record with a different word on it.
  #
  # `fields` is either an attrset of floe types (see types.nix), which is what a
  # signature usually is and what it is named for, or a bare `T` for the case
  # where there are no fields to name — an opaque `T.attrsOf T.any` rendered
  # manifest. One word for both, dispatching on whether the argument is itself a
  # type, because two spellings of one argument is what `docs/adr/0003` deleted
  # elsewhere.
  #
  # A signature carries both halves of that, because they answer different
  # questions and a reader asks each. `shape` is the normalised `T`, which is
  # what `checkValue` seals against. `fields` is the field table — what a
  # signature declares, which is what a generated interface document renders
  # and what the collection-cycle check reads. Empty for a signature with no
  # fields to name.
  #
  # Storing the normalised type under `shape` is what keeps `fields` the plain
  # attrset an author wrote rather than `sig.fields.fields`.
  mkSig =
    {
      name,
      canonicalName ? null,
      description ? null,
      fields,

      # behaviorTest :: anything | null
      #
      # A check that every provider of this signature must pass, carried here
      # and **never run by core**. Compatibility checks a provider's *shape*;
      # nothing checks that a provider of `DATABASE` actually serves one, and
      # that is the gap NixOS RFC 0189's `behaviorTest` names — the closest
      # living relative to this design has it and this did not.
      #
      # Opaque because the two domains have nothing in common: a NixOS provider
      # wants a VM test, a Kubernetes one wants a cluster to apply into. Core
      # would have to know which to run it, so it stores it and a
      # distribution's harness runs it for every provider it finds. Same
      # layering as everywhere else: core owns coherence, distributions own
      # domain legality.
      behaviorTest ? null,
    }:
    if canonicalName == null then
      throw (
        "signature '${name}': needs `canonicalName`, the name a hole or provide of "
        + "it should be called by. Without one, `provides.operator` can mean four "
        + "different signatures and a reader cannot tell which — which is what it "
        + "meant before this was required. `link` checks that no single name is "
        + "used for two signatures."
      )
    else if description == null then
      throw (
        "signature '${name}': needs a one-line `description`. It is what the generated "
        + "interface document says a hole is for, and a comment in this file reaches nothing."
      )
    else
      {
        __floeSig = true;
        inherit
          name
          canonicalName
          description
          ;
        shape = if fields ? tag then fields else types.record fields;
        fields = if fields ? tag then fields.fields or { } else fields;
        inherit behaviorTest;
      };

  renderInputs = lib.mapAttrs (
    _: opt: {
      type = opt.type.description or "unknown";

      default =
        if opt ? defaultText then
          opt.defaultText.text or opt.defaultText
        else if opt ? default then
          builtins.toJSON opt.default
        else
          null;

      description = opt.description or "";
    }
  );

}

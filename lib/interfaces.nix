# Signatures and output kinds. Both are pure data.
{ lib, types }:

{
  # A signature: a named schema for a value a floe commits to, either one that
  # crosses to a peer (`requires`, `optional`, `collects`, `provides`) or one it
  # emits (`out`). There used to be a second constructor, `mkOutputKind`, for
  # the second case; it was the same record with a different word on it.
  #
  # `fields` is either an attrset of floe types (see types.nix), which is what a
  # signature most often is and what it is named for, or a bare `T` for the case
  # where there are no fields to name: an opaque `T.attrsOf T.any` rendered
  # manifest. One word for both, dispatching on whether the argument is itself a
  # type, because two spellings of one argument is what `docs/adr/0003` deleted
  # elsewhere.
  #
  # A signature carries both halves of that, because they answer different
  # questions and a reader asks each. `shape` is the normalised `T`, which is
  # what `checkValue` seals against. `fields` is the field table, what a
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

    }:
    if canonicalName == null then
      throw (
        "signature '${name}': needs `canonicalName`, the name a hole or provide of "
        + "it should be called by. Without one, `provides.operator` can mean four "
        + "different signatures and a reader cannot tell which, which is what it "
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
      };

  # narrows :: Signature -> Signature -> [string]
  #
  # Whether `shared` promises no more than `full`: empty when it is a
  # narrowing of it, one entry per field it added or retyped otherwise.
  #
  # The same relation compatibility decides between a requirer and a provider,
  # pointed the other way and given a name. A distribution carrying a "what
  # crosses a boundary" table rests on it, as catallaxy's `crossable` maps a
  # signature to the form a cluster that does not provide it may read. Nothing
  # was checking it, so a narrowing that *widened* by mistake surfaced where a
  # consumer read the field that was not there.
  narrows = full: shared: types.mismatches [ ] full.shape shared.shape;

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

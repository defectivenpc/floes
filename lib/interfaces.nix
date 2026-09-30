# Signatures and output kinds. Both are pure data.
{ lib, types }:

{
  # A signature: a named record schema over data.
  # fields :: attrset of floe types (see types.nix).
  #
  # A signature: a named schema for a value a floe commits to — one that crosses
  # to a peer (`requires`, `collects`, `provides`) or one it emits (`out`). There
  # used to be a second constructor, `mkOutputKind`, for the second case; it was
  # the same record with a different word on it.
  mkSig =
    {
      name,
      canonicalName ? null,
      description ? null,
      shape,
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
          shape
          ;
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

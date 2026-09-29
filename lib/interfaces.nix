# Signatures and output kinds. Both are pure data.
{ lib, types }:

{
  # A signature: a named record schema over data.
  # fields :: attrset of floe types (see types.nix).
  #
  mkSig =
    {
      name,
      as ? null,
      description ? null,
      fields,
    }:
    if as == null then
      throw (
        "signature '${name}': needs `as`, the canonical name a hole or promise binds it under. "
        + "Without one, `provides.operator` can mean four different signatures and a reader "
        + "cannot tell which — which is what it meant before this was required."
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
          as
          description
          fields
          ;
      };

  isUncrossable = sig: lib.all (t: types.isLocal t) (lib.attrValues sig.fields);

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

  # An output kind: a registered dotted name plus a schema for one class of
  # build product. Kinds are defined by distributions, not floe core.
  mkOutputKind =
    {
      name,
      description ? null,
      schema,
    }:
    if description == null then
      throw "output kind '${name}': needs a one-line `description` saying what it carries."
    else
      {
        __floeKind = true;
        inherit name description schema;
      };
}

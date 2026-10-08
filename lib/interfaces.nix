# Signatures and output kinds. Both are pure data.
{ lib, types }:

rec {
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

      # Whether an inclusion may make this the signature of an export.
      #
      # False for a signature describing a thing that exists in exactly one
      # place, so there is no narrowing of it worth having: a controller that
      # reconciles CRs installed in one cluster, a Secret in one namespace. A
      # peer handed one holds a reference to something that is not there, and
      # every manifest it renders from that reference applies cleanly.
      #
      # Checked where `exports` resolves rather than here, so the signature is
      # still an ordinary `requires`, `provides` and `collects` of a unit —
      # refusing it everywhere would refuse the thing it is for. ADR 0012.
      mayExport ? true,

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
        inherit mayExport;
        shape = if fields ? tag then fields else types.record fields;
        fields = if fields ? tag then fields.fields or { } else fields;
      };

  # project :: { signature; fields; description ? null } -> Signature
  #
  # The form of a signature a peer across a boundary may read: the same
  # signature with every field but the named ones dropped.
  #
  #   provides.mesh = floe.project {
  #     signature = sigs.MESH_NETWORK;
  #     fields = [ "managementURL" ];
  #   };
  #
  # This is what a hand-written narrower twin was. A distribution that shared
  # values across a boundary wrote `MESH_NETWORK_SHARED` beside
  # `MESH_NETWORK`, kept the two in step by hand, and joined them in a table
  # keyed by signature name — so the fact lived in three places and `narrows`
  # had to be *checked* between them. Here it holds by construction, and the
  # full signature is the only definition.
  #
  # `name` and `canonicalName` are carried over, which is not a convenience:
  # resolution matches a hole to a provide by `name`, so a projection that
  # renamed anything would stop resolving against the thing it is a view of.
  #
  # An allowlist rather than a denylist, so a field added to the signature
  # later does not silently begin to cross. The default for a new field is to
  # stay where it is, which is the default `exports` already takes.
  #
  # Nothing a distribution added to its own `mkSig` travels, because core's
  # argument pattern is closed and this calls it with fields alone. That is
  # the right answer rather than a gap: catallaxy's `behaviour` names the
  # runtime checks a provider of a signature owes, those belong to whoever
  # runs the thing and are discharged in that unit's own link, and a boundary
  # re-exporting a view of it runs nothing.
  project =
    {
      signature,
      fields,
      description ? null,
    }:
    let
      have = lib.attrNames signature.fields;
      unknown = lib.subtractLists have fields;
    in
    if (signature.shape.tag or "") != "record" then
      throw (
        "project: '${signature.name}' is ${
          signature.shape.name or "not a record"
        }, so it has no fields to choose between. Projection narrows a record; a signature "
        + "that is one value crosses whole or not at all."
      )
    else if unknown != [ ] then
      throw (
        "project: '${signature.name}' has no field(s) "
        + lib.concatMapStringsSep ", " (f: "'${f}'") unknown
        + ". It has: "
        + (if have == [ ] then "none." else lib.concatStringsSep ", " have + ".")
        + " A name that is not there would narrow to nothing, and a signature promising no "
        + "fields resolves and then fails wherever the value is read."
      )
    else
      mkSig {
        inherit (signature) name canonicalName;
        description =
          if description != null then
            description
          else
            "${signature.description} Narrowed to ${lib.concatStringsSep ", " fields}.";
        fields = lib.filterAttrs (n: _: lib.elem n fields) signature.fields;
      };

  # narrows :: Signature -> Signature -> [string]
  #
  # Whether `shared` promises no more than `full`: empty when it is a
  # narrowing of it, one entry per field it added or retyped otherwise.
  #
  # The same relation compatibility decides between a requirer and a provider,
  # pointed the other way and given a name. It is what an inclusion's
  # re-export of a provide under a narrower signature has to satisfy.
  #
  # `project` above satisfies it by construction, which is the point of having
  # it: a narrowing written by hand had to be checked, and a distribution that
  # kept a table of crossing forms was keeping a second copy of the signature
  # for the relation to hold between.
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

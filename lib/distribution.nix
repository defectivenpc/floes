# What a domain built on floes declares: its kinds, and the document they fold into.
{ lib, types }:

{
  /*
    mkDistribution :: { name; kinds; document; policies ? [ ] } -> Distribution

        mkDistribution {
          name = "catallaxy";
          kinds = { component = …; cd = …; };
          document = import ./document/generated.nix { T = floe.T; };
        }

    A distribution is the half of a floe system a domain owns. The library
    links floes and knows nothing of Kubernetes; the kinds a floe may emit,
    and the shape they fold into, are the domain's.

    `kinds` are the typed channels from a floe *to the distribution*, as
    distinct from signatures, which run between floes. A floe writes
    `out.<canonicalName>` and the linker checks it against the kind with
    `conformValue`; the distribution reads `link.out."<kind name>"` and folds.

    `document` is where that fold ends: the shape handed to whatever consumes
    it, declared once so the fold can be held to it. How a domain arrives at
    the type is its own business — catallaxy generates it from the Rust types
    its CLI parses into, so those types are the single definition.

    What this does *not* do is fold. Merging is domain knowledge — what two
    contributions to one cluster mean, what order they install in — and a
    library that claimed to know would be guessing. The distribution brings
    the fold; this brings the boundary it has to land on.
  */
  mkDistribution =
    {
      name,
      kinds,
      document,
      policies ? [ ],
    }:
    let
      notAKind = lib.filterAttrs (_: k: !(k.__floeSig or false)) kinds;
    in
    if notAKind != { } then
      throw (
        "distribution '${name}': ${lib.concatStringsSep ", " (lib.attrNames notAKind)} "
        + "${if lib.length (lib.attrNames notAKind) == 1 then "is" else "are"} not a kind. "
        + "A kind is `mkSig` — it has a name, a canonical name and a shape — because the "
        + "linker checks a floe's output against it the same way it checks a provide."
      )
    else if !(document ? tag) then
      throw (
        "distribution '${name}': `document` is not a `T` type. It is the shape the "
        + "kinds fold into, and the fold is checked against it; an attrset of fields "
        + "would be a description nothing can hold the fold to."
      )
    else
      {
        __floeDistribution = true;

        inherit
          name
          kinds
          document
          policies
          ;

        /*
          The value a fold produced, checked against the document.

            conformDocument (lowerLab instance)

          Strict: a field the document does not declare is an error rather
          than dropped, because there is no narrowing here. A fold that
          emits a field the consumer never reads has lost the author's
          intent, and the consumer ignoring it silently is how the two
          halves drift.
        */
        conformDocument = value: types.conformValue [ name "document" ] document value;
      };
}

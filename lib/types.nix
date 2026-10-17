# Data schemas for values that cross a floe boundary; a floe's `inputs` use
# native NixOS option types instead. A schema seals by dropping undeclared
# fields, and holds no functions.
{ lib }:

let
  inherit (builtins)
    isString
    isInt
    isBool
    isAttrs
    isList
    typeOf
    match
    elem
    hasAttr
    ;

  short =
    v:
    if isString v then
      "\"${v}\""
    else if isAttrs v then
      "an attrset"
    else if isList v then
      "a list"
    else
      lib.generators.toPretty { multiline = false; } v;
in
rec {
  any = {
    tag = "any";
    name = "any";
    check = _: true;
  };
  str = {
    tag = "str";
    name = "string";
    check = isString;
  };
  int = {
    tag = "int";
    name = "int";
    check = isInt;
  };
  bool = {
    tag = "bool";
    name = "bool";
    check = isBool;
  };

  port = {
    tag = "port";
    name = "port (1-65535)";
    check = v: isInt v && v >= 1 && v <= 65535;
  };

  url = {
    tag = "url";
    name = "url (http/https)";
    check = v: isString v && match "https?://.+" v != null;
  };

  dnsName = {
    tag = "dnsName";
    name = "DNS name";
    check = v: isString v && match "[a-z0-9]([-a-z0-9.]*[a-z0-9])?" v != null;
  };

  # A built thing, as a derivation or as the store path one coerces to. The one
  # way something built crosses a floe boundary, and the reason `out` can carry
  # `environment.systemPackages`: `T.str` refuses a derivation, and `T.any`
  # admits it and then meets `scanTokens`.
  #
  # Distinct from the package *set* a body builds with: which nixpkgs, which
  # overlays and which system are the deployer's choice, so they arrive as an
  # ordinary input under a native NixOS option type. A package set is neither
  # hashable for a cache key nor serialisable; one package is both, since a
  # derivation hashes as its `drvPath` and `toJSON`s as its `outPath`.
  # ADR 0008.
  package = {
    tag = "package";
    name = "package (derivation or store path)";
    check = v: lib.isDerivation v || isString v;
  };

  enum = values: {
    tag = "enum";
    inherit values;
    name = "one of [${lib.concatMapStringsSep ", " (v: "\"${toString v}\"") values}]";
    check = v: elem v values;
  };

  nullOr = inner: {
    tag = "nullOr";
    inherit inner;
    name = "null or ${inner.name}";
  };
  listOf = inner: {
    tag = "listOf";
    inherit inner;
    name = "list of ${inner.name}";
  };
  attrsOf = inner: {
    tag = "attrsOf";
    inherit inner;
    name = "attrs of ${inner.name}";
  };
  # A field computed by folding a collection. The linker withholds it from any
  # unit that contributes to that collection *and* reads it from the unit doing
  # the collecting, which would be a cycle through the fold. Marked here rather
  # than inferred, because only the author of the signature knows.
  derivedFrom = sig: inner: {
    tag = "derivedFrom";
    inherit sig inner;
    name = "${inner.name} derived from ${sig.name}";
  };

  # derivedFromName :: type -> SignatureName | null
  derivedFromName = ty: if (ty.tag or "") == "derivedFrom" then ty.sig.name else null;

  # A value that does not exist until after apply. Carried as a token; reading
  # one where a concrete value is required is an error naming its source.
  deferred = inner: {
    tag = "deferred";
    inherit inner;
    name = "deferred ${inner.name}";
  };

  moduleType = inner: {
    tag = "moduleType";
    inherit inner;
    name = "module type ${inner.description or "<anonymous>"}";
  };

  # A record: all declared fields must be present and well-typed.
  # Checking a record also *restricts* to the declared fields (opaque sealing).
  record = fields: {
    tag = "record";
    inherit fields;
    name = "record { ${lib.concatStringsSep ", " (lib.attrNames fields)} }";
  };

  # optional :: Type -> Type
  #
  # A record field that may be absent. Present, it is checked as its type;
  # absent, it is absent — which is not the same as null, and is why
  # `nullOr` cannot say this.
  #
  #   T.record {
  #     repo = T.str;
  #     branch = T.optional T.str;
  #   }
  #
  # Only meaningful inside `record`. A producer that always writes the field
  # should not mark it: the point of a required field is that forgetting it is
  # an error, and `optional` gives that up.
  optional = ty: ty // { optionalField = true; };

  # named :: string -> Type -> Type
  #
  #   bundle = T.named "bundle" (T.record { … });
  #
  # A separate combinator rather than an argument to `record`, because
  # `record`'s argument is the field table and records have fields called
  # `name` — one key cannot mean both. It also names an `attrsOf` or a
  # `listOf`, which `record` could not.
  #
  # `checkValue` prints `ty.name`, so this is what turns
  # `expected record { chart, releaseName, … }` into `expected helmChart`.
  named = name: ty: ty // { inherit name; };

  taggedUnion = variants: {
    tag = "taggedUnion";
    inherit variants;
    name = "tagged union { ${lib.concatStringsSep " | " (lib.attrNames variants)} }";
  };

  isDeferredToken = v: isAttrs v && (v.__deferred or false) == true;

  # ---- Compatibility ------------------------------------------------------
  #
  # Whether a provider's shape answers a requirer's. Resolution keys on a
  # signature's `name`, a bare string, so two definitions of one name used to
  # link cleanly and then fail where the value was read, with
  # `attribute 'port' missing`, naming no floe, no field and no provider, and
  # not catchable by `tryEval`. This is the check that makes a third-party
  # floe's version skew an error at link. ADR 0007.
  #
  # The rule is provider `<:` requirer with ordinary covariance: the provider
  # must promise at least as much, and extra fields are what sealing drops.

  # A refinement satisfies what it refines: every port is an int, every DNS
  # name a string. Without this, a provider promising *more* than the requirer
  # asked for would be refused, which is the wrong direction.
  refines = {
    port = "int";
    dnsName = "str";
    url = "str";
  };

  # mismatches :: [string] -> providerType -> requirerType -> [string]
  # Empty when the provider answers. One entry per incompatible field, each
  # naming its dotted path, because a signature that moved tends to move once.
  mismatches =
    path: p: r:
    let
      pt = p.tag or "?";
      rt = r.tag or "?";
      fail = pth: msg: [ "${if pth == [ ] then "<value>" else lib.concatStringsSep "." pth}: ${msg}" ];
      no = fail path;
      offers = "provider offers ${p.name or "?"}, requirer declared ${r.name or "?"}";
    in
    # A requirer that accepts anything is answered by anything.
    if rt == "any" then
      [ ]
    # `derivedFrom` says where a field came from, not what it is.
    else if pt == "derivedFrom" then
      mismatches path p.inner r
    else if rt == "derivedFrom" then
      mismatches path p r.inner
    # The one asymmetry, and the valuable one. A concrete value answers a
    # requirer that declared the field deferred, because that requirer already
    # handles both. The reverse cannot work: the value does not exist at the
    # moment the requirer would read it, so this moves a read-time error to the
    # header check, where it can name both sides.
    else if rt == "deferred" then
      mismatches path (if pt == "deferred" then p.inner else p) r.inner
    else if pt == "deferred" then
      no (
        "${offers}. A value that does not exist until after apply cannot satisfy "
        + "a field read at evaluation time."
      )
    else if rt == "nullOr" then
      mismatches path (if pt == "nullOr" then p.inner else p) r.inner
    # A provider that may be null, or may be anything, against a requirer that
    # said neither.
    else if pt == "any" || pt == "nullOr" then
      no offers
    else if pt != rt then
      (if (refines.${pt} or null) == rt then [ ] else no offers)
    else if pt == "record" then
      lib.concatLists (
        lib.mapAttrsToList (
          f: rty:
          if p.fields ? ${f} then
            mismatches (path ++ [ f ]) p.fields.${f} rty
          else
            fail (path ++ [ f ]) "the requirer declares it and the provider's signature has no such field"
        ) r.fields
      )
    else if pt == "listOf" || pt == "attrsOf" then
      mismatches path p.inner r.inner
    else if pt == "enum" then
      (
        let
          extra = lib.subtractLists r.values p.values;
        in
        if extra == [ ] then
          [ ]
        else
          no (
            "provider may also be ${lib.concatMapStringsSep ", " (v: "\"${toString v}\"") extra}, "
            + "which the requirer's ${r.name} does not admit"
          )
      )
    else if pt == "taggedUnion" then
      (
        let
          extra = lib.subtractLists (lib.attrNames r.variants) (lib.attrNames p.variants);
        in
        if extra != [ ] then
          no (
            "provider may also be variant(s) ${lib.concatStringsSep ", " extra}, which the "
            + "requirer does not admit"
          )
        else
          lib.concatLists (
            lib.mapAttrsToList (v: pty: mismatches (path ++ [ v ]) pty r.variants.${v}) p.variants
          )
      )
    # An option type holds functions, so there is nothing to compare
    # structurally. Its `name` is what nixpkgs itself identifies it by.
    else if pt == "moduleType" then
      (if (p.inner.name or null) == (r.inner.name or null) then [ ] else no offers)
    else
      # Same leaf tag, and a leaf carries nothing further to disagree about.
      [ ];

  # conformValue :: [string] -> type -> value -> value
  #
  # `checkValue`, and a record field the type does not declare is an error
  # rather than dropped.
  #
  # The two differ because dropping is load-bearing in one place and wrong in
  # the other. Where a value crosses a narrow signature the drop *is* the seal
  # — `link.nix`'s `sealSig` relies on it, and a signature carrying less than
  # the value offered is how a boundary keeps a field local. Where a floe
  # authors an output kind there is no narrowing: a field the kind does not
  # have is a field the author believed in, and silence loses their intent
  # with no message.
  #
  # Misspelling an existing field was always caught, because the field it
  # should have been goes missing. This catches the other mistake.
  conformValue = checkValue' true;

  # checkValue :: [string] -> type -> value -> value
  # Throws with a dotted path on mismatch; returns the (restricted) value.
  checkValue = checkValue' false;

  checkValue' =
    strict: path: ty: v:
    let
      where = if path == [ ] then "<value>" else lib.concatStringsSep "." path;
      fail = msg: throw "floe type error at ${where}: ${msg}";
    in
    if isAttrs ty && (ty._type or null) == "option-type" then
      fail (
        "declared with `lib.types.${ty.name or "?"}`, a NixOS option type. A value "
        + "that crosses a floe boundary is declared with `T`; only a floe's `inputs` "
        + "use NixOS types. See lib/types.nix."
      )
    else if !(ty ? tag) then
      fail "declared with something that is not a floe type"
    else if ty.tag == "any" then
      v
    else if ty.tag == "derivedFrom" then
      checkValue' strict path ty.inner v
    else if ty.tag == "deferred" then
      (if isDeferredToken v then v else checkValue' strict path ty.inner v)
    else if isDeferredToken v then
      fail (
        "got a deferred value where concrete ${ty.name} is required. It comes from "
        + "'${toString (v.source or "?")}' and will be readable via "
        + "'${toString (v.retrieval or "?")}' once that has been applied, so it "
        + "cannot be used at evaluation time."
      )
    else if ty.tag == "nullOr" then
      (if v == null then v else checkValue' strict path ty.inner v)
    else if ty.tag == "listOf" then
      (
        if !isList v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else
          lib.imap0 (i: x: checkValue' strict (path ++ [ (toString i) ]) ty.inner x) v
      )
    else if ty.tag == "attrsOf" then
      (
        if !isAttrs v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else
          lib.mapAttrs (n: x: checkValue' strict (path ++ [ n ]) ty.inner x) v
      )
    else if ty.tag == "moduleType" then
      (
        let
          evaluated =
            (lib.evalModules {
              modules = [
                { options.value = lib.mkOption { type = ty.inner; }; }
                {
                  value = v;
                  _file = where;
                }
              ];
            }).config.value;
        in
        builtins.deepSeq evaluated evaluated
      )
    else if ty.tag == "record" then
      (
        if !isAttrs v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else
          let
            isOptional = f: ty.fields.${f}.optionalField or false;

            missing = lib.filter (f: !(hasAttr f v) && !isOptional f) (lib.attrNames ty.fields);
            unknown = lib.subtractLists (lib.attrNames ty.fields) (lib.attrNames v);

            # Only the fields the value has. Mapping over the declaration
            # would force `v.${f}` for an absent optional one.
            present = lib.filterAttrs (f: _: hasAttr f v) ty.fields;
          in
          if missing != [ ] then
            fail "missing field(s): ${lib.concatStringsSep ", " missing}"
          else if strict && unknown != [ ] then
            fail (
              "unknown field(s): ${lib.concatStringsSep ", " unknown}. "
              + "${ty.name} declares: ${lib.concatStringsSep ", " (lib.attrNames ty.fields)}"
            )
          else
            lib.mapAttrs (f: fty: checkValue' strict (path ++ [ f ]) fty v.${f}) present
      )
    else if ty.tag == "taggedUnion" then
      (
        let
          known = lib.attrNames ty.variants;
          expected = "expected exactly one of [${lib.concatStringsSep ", " known}]";
          present = lib.attrNames v;
          unknown = lib.subtractLists known present;
        in
        if !isAttrs v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else if unknown != [ ] then
          fail "no variant named ${lib.concatMapStringsSep ", " (n: "'${n}'") unknown}; ${expected}"
        else if present == [ ] then
          fail "names no variant; ${expected}"
        else if lib.length present > 1 then
          fail (
            "names ${toString (lib.length present)} variants at once "
            + "(${lib.concatStringsSep ", " present}); a tagged union carries one. ${expected}"
          )
        else
          let
            k = lib.head present;
          in
          {
            ${k} = checkValue' strict (path ++ [ k ]) ty.variants.${k} v.${k};
          }
      )
    else if ty ? check then
      (if ty.check v then v else fail "expected ${ty.name}, got ${short v}")
    else
      fail "unknown floe type (tag: ${toString (ty.tag or "missing")})";
}

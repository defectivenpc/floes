# Data schemas for values that cross a floe boundary; a floe's `inputs` use
# native NixOS option types instead. Each carries `T.local` per field, seals
# by dropping undeclared fields, and holds no functions.
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
  deferred = inner: {
    tag = "deferred";
    inherit inner;
    name = "deferred ${inner.name}";
  };

  local = inner: {
    tag = "local";
    inherit inner;
    name = "link-local ${inner.name}";
  };

  isLocal = ty: (ty.tag or "") == "local";

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

  taggedUnion = variants: {
    tag = "taggedUnion";
    inherit variants;
    name = "tagged union { ${lib.concatStringsSep " | " (lib.attrNames variants)} }";
  };

  isDeferredToken = v: isAttrs v && (v.__deferred or false) == true;

  # checkValue :: [string] -> type -> value -> value
  # Throws with a dotted path on mismatch; returns the (restricted) value.
  checkValue =
    path: ty: v:
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
    else if ty.tag == "local" then
      checkValue path ty.inner v
    else if ty.tag == "deferred" then
      (if isDeferredToken v then v else checkValue path ty.inner v)
    else if isDeferredToken v then
      fail (
        "got a deferred value (from '${toString (v.source or "?")}', resolves "
        + "'${toString (v.phase or "later")}') where concrete ${ty.name} is required"
      )
    else if ty.tag == "nullOr" then
      (if v == null then v else checkValue path ty.inner v)
    else if ty.tag == "listOf" then
      (
        if !isList v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else
          lib.imap0 (i: x: checkValue (path ++ [ (toString i) ]) ty.inner x) v
      )
    else if ty.tag == "attrsOf" then
      (
        if !isAttrs v then
          fail "expected ${ty.name}, got ${typeOf v}"
        else
          lib.mapAttrs (n: x: checkValue (path ++ [ n ]) ty.inner x) v
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
            missing = lib.filter (f: !(hasAttr f v)) (lib.attrNames ty.fields);
          in
          if missing != [ ] then
            fail "missing field(s): ${lib.concatStringsSep ", " missing}"
          else
            lib.mapAttrs (f: fty: checkValue (path ++ [ f ]) fty v.${f}) ty.fields
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
            ${k} = checkValue (path ++ [ k ]) ty.variants.${k} v.${k};
          }
      )
    else if ty ? check then
      (if ty.check v then v else fail "expected ${ty.name}, got ${short v}")
    else
      fail "unknown floe type (tag: ${toString (ty.tag or "missing")})";
}

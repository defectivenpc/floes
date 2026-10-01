# mkFloe: a unit with declared surfaces (inputs, requires, collects, provides,
# out) and a body that is either a plain function or NixOS-style modules.
{ lib, types }:

rec {
  # isInstance :: a -> bool
  #
  # Marked rather than inferred: both shapes are an attrset with a `def`.
  isInstance = v: (v.__floeInstance or false) == true;

  # The module-system type for an option holding one.
  #
  # `raw`, because two instances have no merge.
  instanceType = lib.types.raw // {
    name = "floeInstance";
    description = "an instantiated floe";
    check = isInstance;
  };

  # Runtime-token constructor, exposed to bodies as `floe.mkRuntime` and bound
  # to the unit's link name.
  #
  #   mkRuntime <retrieval signature> <ref>
  #
  # A value that does not exist until after apply, and a declaration of where it
  # will be readable once it does. The *provider* says where, because it is the
  # thing that creates the value: cert-manager knows it writes a Secret, postgres
  # knows it writes a file. So one signature — `DATABASE.password` — survives two
  # domains with two mechanisms, which it could not if the retrieval were welded
  # to the field's type.
  #
  # Core checks `ref` against the retrieval signature's shape and records the
  # signature's name. It never looks inside, and never learns what a Secret is:
  # reading the value is a backend's job, and there may be many backends for one
  # retrieval — a ConfigMap, a Secret, an annotation, a file, an HTTP lookup.
  # `link.runtimeSites` is what a backend reads to find the work.
  mkRuntimeFor =
    instName: sig: ref:
    if !(sig.__floeSig or false) then
      throw (
        "floe '${instName}': `mkRuntime` takes a retrieval signature and a ref — "
        + "`mkRuntime SECRET_REF { namespace = …; name = …; }`. The signature says "
        + "where the value will be readable; a backend implements how to read it."
      )
    else
      {
        __runtime = true;
        source = instName;
        retrieval = sig.name;
        ref = types.checkValue [ instName "runtime" sig.name ] sig.shape ref;
      };

  mkFloe =
    {
      name,

      summary ? null,

      inputs ? { },
      requires ? { },

      collects ? { },
      provides ? { },
      out ? { },
      # A body is either `modules` — ordinary NixOS modules, for a floe that wants
      # the module system's merge inside itself — or `body`, a plain function.
      # Most floes never merge anything, and pay a whole `evalModules` for the
      # privilege; `body` is the same floe without it.
      #
      #   body = { inputs, requires, collects, floe }: { provides, out };
      #
      # `provides` still has to be *declared* above even with `body`, because the
      # linker resolves every hole from headers before any body evaluates. That is
      # what makes a link's wiring checkable without running anything.
      modules ? [ ],
      body ? null,

      # singleton :: bool
      #
      # Whether two instances of this floe in one link is an error.
      #
      # It is the author's to declare, because only the author knows whether the
      # body keys its output by `config.floe.name`. A floe that writes fixed
      # paths — `services.nginx`, `networking.firewall` — cannot be instantiated
      # twice: both instances emit the same paths, and *identical* values merge
      # without complaint, so the deployer gets one of the thing and believes
      # they have two. Nothing downstream can catch that; the values agree.
      #
      # Conflicting values are caught, by whatever consumes the output. This is
      # for the case where they agree.
      singleton ? false,
    }:
    let
      _ =
        if summary == null then
          throw (
            "floe '${name}': needs a one-line `summary` saying what it installs. "
            + "Nix cannot read comments, so the header prose above reaches no tool; "
            + "this is the line the generated interface document titles it with."
          )
        else
          null;

      _bodyForm =
        if body != null && modules != [ ] then
          throw (
            "floe '${name}': has both `body` and `modules`. They are two spellings of "
            + "one thing — `body` is a plain function, `modules` is the NixOS module "
            + "system with its merge. Pick the one the floe needs."
          )
        else if body != null && !lib.isFunction body then
          throw "floe '${name}': `body` must be a function of { inputs, requires, collects, floe }."
        else
          null;

      # An input is what a deployer writes, so it takes a NixOS option type.
      # A floe data schema fails deep inside nixpkgs, naming neither the floe
      # nor the input.
      floeTypedInputs = lib.attrNames (
        lib.filterAttrs (_: opt: lib.isAttrs opt && ((opt.type or null) ? tag)) inputs
      );

      _inputTypes =
        if floeTypedInputs == [ ] then
          null
        else
          throw (
            "floe '${name}': input(s) ${lib.concatStringsSep ", " floeTypedInputs} are "
            + "declared with `T`, the floe data schema. An input is what a deployer "
            + "writes, so it takes a NixOS option type — `lib.types.str`, not `T.str`. "
            + "`T` is for values that cross a floe boundary."
          );

      # checkInputs: validate and default-fill what a deployer passed.
      #
      # `lib.modules.mergeDefinitions` is the NixOS module system's own
      # per-option machinery — the same code that checks `services.nginx.enable`,
      # asked about one option rather than a whole tree. It handles `mkIf`,
      # `mkMerge`, `mkOverride` and `mkOrder`, and delegates to `type.merge`,
      # which is what fills a submodule's nested defaults.
      #
      # This used to be a whole `lib.evalModules` per floe, which is the
      # whole-tree entry point and the only reason a submodule's defaults were
      # reachable. Per option instead costs 6MB against 107MB for a thousand
      # floes of fifteen inputs, with the same semantics. `bench/run.sh`.
      #
      # `mergeDefinitions` is exported from `lib.modules` under a blanket note
      # that not everything in that list is a public interface. The risk is
      # accepted, because the alternative is maintaining a worse copy of it —
      # and `tests/default.nix` pins the three behaviours we rely on, so a
      # nixpkgs bump that moves them fails the suite rather than a deploy.
      checkInputs =
        supplied:
        let
          declared = lib.attrNames inputs;
          suppliedNames = lib.attrNames supplied;

          # Eager: the *shape* of the call. A typo'd key or a forgotten required
          # input is wrong whether or not anything reads it, and neither check
          # forces a value.
          undeclared = lib.subtractLists declared suppliedNames;
          unsupplied = lib.filter (n: !(supplied ? ${n}) && !(inputs.${n} ? default)) declared;

          # Lazy: the values. NixOS is lazy here too — a badly-typed option that
          # nothing reads does not fail a real system evaluation — and a floe
          # author's mental model should be the one they already have.
          valueOf =
            n:
            let
              opt = inputs.${n};
              merged =
                (lib.modules.mergeDefinitions [ "floe" name "inputs" n ] opt.type [
                  {
                    file = "the arguments to floe '${name}'";
                    value = if supplied ? ${n} then supplied.${n} else opt.default;
                  }
                ]).mergedValue;
            in
            # `mergeDefinitions` does not run `apply`; that is `evalOptionValue`'s
            # job, and this is a level below it.
            if opt ? apply then opt.apply merged else merged;
        in
        if undeclared != [ ] then
          throw (
            "floe '${name}': got input(s) it does not declare: "
            + lib.concatStringsSep ", " undeclared
            + ". It declares: "
            + (if declared == [ ] then "none." else lib.concatStringsSep ", " declared + ".")
          )
        else if unsupplied != [ ] then
          throw (
            "floe '${name}': input(s) with no default were not supplied: "
            + lib.concatStringsSep ", " unsupplied
            + ". Pass them to `.instantiate { … }`."
          )
        else
          lib.genAttrs declared valueOf;

      def = builtins.seq _ (
        builtins.seq _bodyForm (
          builtins.seq _inputTypes {
            __floeDef = true;
            inherit
              name
              summary
              inputs
              requires
              collects
              provides
              out
              modules
              body
              singleton
              ;

            # instantiate :: attrset -> instance
            # `inputsChecked` is validated and defaults-filled; `supplied` is
            # verbatim, and wins when the floe is re-instantiated.
            instantiate =
              supplied:
              let
                inst = {
                  __floeInstance = true;
                  inherit def supplied;
                  inputsChecked = checkInputs supplied;
                  bindings = { };

                  # bind :: { Hole -> "<unit>" | "<unit>/<provide>" } -> instance
                  # Which provider a hole means, when the deployer has two. The
                  # author cannot say: a floe does not know its peers' names.
                  bind = b: inst // { bindings = inst.bindings // b; };
                };
              in
              inst;
          }
        )
      );
    in
    def;

  # evalFloe: evaluate one floe's body with its resolved holes injected, and
  # return `{ provides, out }` whichever form the body took. The linker only ever
  # sees the normalised shape, so `body` and `modules` are interchangeable to it.
  #
  # Not part of the author-facing API.
  evalFloe =
    {
      instance,
      instName,
      resolvedRequires,
      resolvedCollects ? { },
    }:
    let
      def = instance.def;

      # What a body is handed either way. `name` is here because a floe that can
      # be instantiated twice has to key its output by it.
      floeArg = {
        name = instName;
        mkRuntime = mkRuntimeFor instName;
      };

      viaBody =
        let
          r = def.body {
            inputs = instance.inputsChecked;
            requires = resolvedRequires;
            collects = resolvedCollects;
            floe = floeArg;
          };
          unknown = lib.subtractLists [ "provides" "out" ] (lib.attrNames r);
        in
        if unknown != [ ] then
          throw (
            "floe '${instName}': its `body` returned unknown key(s) "
            + "${lib.concatStringsSep ", " unknown}. A body returns { provides, out }."
          )
        else
          {
            provides = r.provides or { };
            out = r.out or { };
          };

      viaModules =
        let
          t = lib.types;
          base = {
            options.floe = {
              name = lib.mkOption {
                type = t.str;
                default = instName;
              };
              inputs = lib.mkOption {
                type = t.raw;
                default = instance.inputsChecked;
              };
              requires = lib.mkOption {
                type = t.raw;
                default = resolvedRequires;
              };
              collects = lib.mkOption {
                type = t.raw;
                default = resolvedCollects;
              };
              provides = lib.mkOption {
                type = t.attrsOf t.raw;
                default = { };
              };
              out = lib.mapAttrs (
                _name: _sig:
                lib.mkOption {
                  type = t.attrsOf t.raw;
                  default = { };
                }
              ) def.out;
            };
          };
          ev = lib.evalModules {
            specialArgs.floe = floeArg;
            modules = def.modules ++ [ base ];
          };
        in
        {
          inherit (ev.config.floe) provides out;
        };
    in
    if def.body != null then viaBody else viaModules;
}

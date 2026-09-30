# mkFloe: a unit with declared surfaces (inputs, requires, requiresOptional,
# provides, out) and a body of ordinary NixOS-style modules.
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

  # Deferred-value token constructor, exposed to bodies as `floe.mkRuntime`
  # via specialArgs (bound to the unit's link name).
  mkRuntimeFor = instName: path: {
    __runtime = true;
    source = instName;
    inherit path;
    phase = "post-apply";
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

      hasInputs = inputs != { };

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

      checkInputs =
        supplied:
        if !hasInputs then
          (
            if supplied == { } then
              supplied
            else
              throw (
                "floe '${name}': takes no inputs, but got: " + lib.concatStringsSep ", " (lib.attrNames supplied)
              )
          )
        else
          let
            ev = lib.evalModules {
              modules = [
                { options.floe.inputs = inputs; }
                { config.floe.inputs = supplied; }
              ];
            };
          in
          builtins.addErrorContext "while instantiating floe '${name}'" (
            builtins.deepSeq ev.config.floe.inputs ev.config.floe.inputs
          );

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

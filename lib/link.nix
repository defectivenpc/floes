# link: resolve holes by signature name, tie the graph with lib.fix, seal
# provides against signatures, collect outputs by signature name, scan for
# runtime tokens to derive deploy edges and phases, then run policies.
{
  lib,
  types,
  interfaces,
  floeLib,
}:

let
  # candidatesFor :: Catalogue -> SignatureName -> [FloeName]
  # Named, because a throw's text is unreachable from `builtins.tryEval` and
  # this is the only part of the message a test can hold.
  candidatesFor =
    catalogue: sigName:
    lib.attrNames (lib.filterAttrs (_: sigNames: lib.elem sigName sigNames) catalogue);
in
{
  inherit candidatesFor;

  link =
    {
      units,
      policies ? [ ],

      # defaults :: { SignatureName -> "<unit>" | "<unit>/<provide>" }
      #
      # Which provider a hole means when its consumer did not say. The deployer's,
      # in one place, and applied only where a unit gave no `.bind` of its own —
      # so adding a second provider stops being a breaking change to every
      # existing consumer, without making ambiguity silent where nobody decided.
      defaults ? { },

      # catalogue :: { FloeName -> [SignatureName] }
      # What could fill an unfilled hole. Forced on the error path alone, and
      # a parameter because core knows no floe set.
      catalogue ? { },
    }:
    let
      instNames = lib.attrNames units;

      getInstance =
        u:
        let
          inst = units.${u};
        in
        if floeLib.isInstance inst then
          inst
        else
          throw "floe link error: unit '${u}' is not an instantiated floe (call .instantiate { ... } on it)";

      # ---- Resolution (headers only; no body evaluation) -------------------

      # Every provide in the link, grouped by the signature name it answers.
      #
      # Built once, because the arity rules ask "who provides this?" once per
      # hole and the obvious implementation — scan every unit's provides, per
      # hole — is O(units x holes). Two of them, in fact: `wiringOne` and
      # `selfResolutions` each did their own pass. At a thousand of each that
      # was 1.1s and 586MB of the 1.3s a link took, against 0.17s and 129MB
      # for this. `bench/run.sh` is the measurement.
      providerIndex = lib.groupBy (p: p.sigName) (
        lib.concatMap (
          u:
          let
            provs = (getInstance u).def.provides;
          in
          map (provideName: {
            sigName = provs.${provideName}.name;
            instName = u;
            inherit provideName;
          }) (lib.attrNames provs)
        ) instNames
      );

      # `sigName` is the index's key and not part of a provider reference —
      # these records reach `result.wiring`, where an extra field would show.
      providersOf = sigName: map (p: removeAttrs p [ "sigName" ]) (providerIndex.${sigName} or [ ]);

      describeProviders =
        ps: lib.concatMapStringsSep ", " (p: "'${p.instName}' (as ${p.provideName})") ps;

      # Every surface of every floe, as (floe, surface, holeName, signature).
      # One list, because four separate walks of the same data is four places to
      # forget a surface.
      allSurfaces = lib.concatMap (
        u:
        let
          def = (getInstance u).def;
        in
        lib.concatMap
          (
            surface:
            lib.mapAttrsToList (holeName: sig: {
              inherit
                u
                surface
                holeName
                sig
                ;
            }) def.${surface}
          )
          [
            "requires"
            "collects"
            "provides"
            "out"
          ]
      ) instNames;

      # A name may not mean two different signatures.
      #
      # Not the other direction: a floe may legitimately hold two holes on one
      # signature — a primary and a replica database — so a signature cannot be
      # pinned to a single name. What goes wrong in practice is the reverse, and
      # it is what `canonicalName` exists to prevent: `provides.operator` meaning
      # four different things across a catalogue, so a reader cannot tell which.
      nameCollisions =
        let
          byName = lib.groupBy (e: e.holeName) allSurfaces;
          ambiguous = lib.filterAttrs (_: es: lib.length (lib.unique (map (e: e.sig.name) es)) > 1) byName;
        in
        lib.mapAttrsToList (
          holeName: es:
          "'${holeName}' names ${toString (lib.length (lib.unique (map (e: e.sig.name) es)))} signatures: "
          + lib.concatMapStringsSep ", " (
            e: "'${e.sig.name}' (${e.u}'s ${e.surface}, canonically '${e.sig.canonicalName}')"
          ) es
        ) ambiguous;

      selfResolutions = lib.concatMap (
        u:
        let
          inst = getInstance u;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            hole: sig:
            map (
              p: "floe '${u}' requires '${sig.name}' as hole '${hole}' and also provides it (as ${p.provideName})"
            ) (lib.filter (p: p.instName == u) (providersOf sig.name))
          ) inst.def.requires
        )
      ) instNames;

      # Two instances of a floe that declared itself a singleton. Its body writes
      # fixed paths rather than keying them by `config.floe.name`, so both
      # instances emit the same output — and identical values merge without
      # complaint wherever that output lands. The deployer gets one of the thing
      # and believes they have two, with no error anywhere downstream, which is
      # why this one has to be caught here.
      singletonBreaches =
        let
          declared = lib.filter (u: (getInstance u).def.singleton) instNames;
          byFloe = lib.groupBy (u: (getInstance u).def.name) declared;
        in
        lib.mapAttrsToList (
          floeName: us:
          "floe '${floeName}' is a singleton, instantiated ${toString (lib.length us)} times: "
          + lib.concatMapStringsSep ", " (u: "'${u}'") us
        ) (lib.filterAttrs (_: us: lib.length us > 1) byFloe);

      # Which provider a hole means: the unit's own `.bind` first, then the
      # link's `defaults` for that signature, then nothing.
      wantedBy =
        u: hole: sig:
        (getInstance u).bindings.${hole} or (defaults.${sig.name} or null);

      narrowed =
        u: hole: sig: ps:
        let
          want = wantedBy u hole sig;
          matches = p: p.instName == want || "${p.instName}/${p.provideName}" == want;
          kept = lib.filter matches ps;
        in
        if want == null then
          ps
        # A default that names nothing here is not an error: it is a default for
        # a signature this link may not even use. A `.bind` that names nothing is.
        else if kept == [ ] then
          if (getInstance u).bindings ? ${hole} then
            throw (
              "floe link error: unit '${u}' binds hole '${hole}' to '${want}', which does not "
              + "provide '${sig.name}' here. Provided by: ${describeProviders ps}."
            )
          else
            ps
        else if lib.length kept > 1 then
          throw (
            "floe link error: '${want}' provides '${sig.name}' more than once: "
            + "${describeProviders kept}. Name the provide too, as `<unit>/<provide>`."
          )
        else
          kept;

      wiringOne = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (
          hole: sig:
          let
            ps = narrowed u hole sig (providersOf sig.name);
          in
          if ps == [ ] then
            let
              candidates = candidatesFor catalogue sig.name;
            in
            throw (
              "floe link error: no provider for signature '${sig.name}' "
              + "(required by '${u}' as hole '${hole}').\n"
              + "  In this link: ${lib.concatStringsSep ", " instNames}\n"
              + (
                if candidates == [ ] then
                  "  Nothing available provides it."
                else
                  "  Provided by: ${lib.concatStringsSep ", " candidates}. Add one to this link."
              )
            )
          else if lib.length ps > 1 then
            throw (
              "floe link error: signature '${sig.name}' (required by unit "
              + "'${u}' as hole '${hole}') is provided by multiple units: "
              + "${describeProviders ps}. Say which this unit means with "
              + "`.bind { ${hole} = \"<unit>\"; }`, or which every unit means with "
              + "`link { defaults.${sig.name} = \"<unit>\"; }`, or remove one."
            )
          else
            lib.head ps
        ) inst.def.requires
      ) (lib.genAttrs instNames getInstance);

      # The second arity: every provider rather than the one. This link's own
      # units, and never the collecting unit itself — a floe that answers the
      # signature reads its own provide and needs no link to do it.
      wiringAll = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (_hole: sig: lib.filter (p: p.instName != u) (providersOf sig.name)) inst.def.collects
      ) (lib.genAttrs instNames getInstance);

      # ---- Withholding a field derived from a collection --------------------
      #
      # `T.derivedFrom C inner` marks a field a provider computed by folding its
      # collection of `C`. A consumer that *contributes* a `C` to that same
      # provider and then reads the field closes the loop: computing its own
      # contribution needs the fold, and the fold needs its contribution. Nix
      # says `infinite recursion encountered`, names nothing, and `tryEval`
      # cannot even catch it.
      #
      # So the linker refuses the field instead, before anything evaluates. Both
      # facts it needs are in the headers: who provides `C`, and who collects it.
      collectsSig =
        u: sigName: lib.any (sig: sig.name == sigName) (lib.attrValues (getInstance u).def.collects);

      providesSig = u: sigName: lib.any (p: p.instName == u) (providersOf sigName);

      # withheld :: consumer -> providerUnit -> signature -> value -> value
      withheld =
        u: from: sig: value:
        let
          fields = sig.shape.fields or { };
        in
        if (sig.shape.tag or "") != "record" then
          value
        else
          lib.mapAttrs (
            field: v:
            let
              # Always present: `value` arrived already sealed by its provider,
              # so its keys are exactly this shape's fields.
              c = types.derivedFromName fields.${field};
            in
            if c != null && providesSig u c && collectsSig from c then
              throw (
                "floe link error: '${sig.name}.${field}' is derived from the '${c}' "
                + "collection that '${from}' folds, and '${u}' contributes a '${c}' to "
                + "it. Reading it here is a cycle: the fold needs '${u}'s contribution, "
                + "and '${u}' would need the fold.\n\n"
                + "This is the one read that cannot work. Every other field of "
                + "'${sig.name}' is fine from '${u}' — it is the field, not the hole, "
                + "that closes the loop."
              )
            else
              v
          ) value;

      # ---- Evaluation fixpoint ---------------------------------------------

      sealSig =
        path: sig: v:
        types.checkValue path sig.shape v;

      fixed = lib.fix (
        self:
        lib.genAttrs instNames (
          u:
          let
            inst = getInstance u;

            valueOf = p: self.${p.instName}.sealedProvides.${p.provideName};

            resolved = lib.mapAttrs (
              hole: p: withheld u p.instName inst.def.requires.${hole} (valueOf p)
            ) wiringOne.${u};

            # Keyed by the providing unit, so a consumer folding over them
            # can name one, and two providers cannot collide.
            collected = lib.mapAttrs (
              _hole: ps: lib.listToAttrs (map (p: lib.nameValuePair p.instName (valueOf p)) ps)
            ) wiringAll.${u};
          in
          rec {
            evaluated = floeLib.evalFloe {
              instance = inst;
              instName = u;
              resolvedRequires = resolved;
              resolvedCollects = collected;
            };
            sealedProvides = lib.mapAttrs (
              provideName: sig:
              let
                v =
                  evaluated.provides.${provideName} or (throw (
                    "floe '${u}': declares provide '${provideName}' (signature "
                    + "'${sig.name}') but its body never defines it"
                  ));
              in
              sealSig [ u "provides" provideName ] sig v
            ) inst.def.provides;
            outs = lib.mapAttrs (
              name: sig: types.checkValue [ u "out" name ] sig.shape (evaluated.out.${name} or { })
            ) inst.def.out;
          }
        )
      );

      # ---- Graph derivation ------------------------------------------------

      # Every runtime token in a value, with the path it sits at.
      #
      # The path is a *list* and not a dotted string, because output keys contain
      # dots — a Kubernetes annotation is `floe.dev/ca-fingerprint`, and a backend
      # that had to split a string there would write to the wrong place.
      scanTokens =
        at: v:
        if types.isRuntimeToken v then
          [
            {
              inherit at;
              token = v;
            }
          ]
        else if builtins.isAttrs v then
          lib.concatLists (lib.mapAttrsToList (k: scanTokens (at ++ [ k ])) v)
        else if builtins.isList v then
          lib.concatLists (lib.imap0 (i: scanTokens (at ++ [ i ])) v)
        else
          [ ];

      # runtimeSites :: [{ unit; out; at; token; }]
      #
      # Where a value that does not exist yet has been written into output, and
      # what a backend needs to read to fill it in. Core's whole contribution to
      # the problem: it knows the work exists and exposes it, and knows nothing
      # about how any of it is done.
      #
      # A backend walks this before applying anything, checks every `token.retrieval`
      # against the resolvers it implements, and refuses to start rather than
      # failing halfway. That check cannot live here: only the backend knows what
      # it can resolve, so a list of resolvers in the link would be a claim about
      # the backend that core could not verify.
      runtimeSites = lib.concatMap (
        u:
        lib.concatLists (
          lib.mapAttrsToList (
            outName: outValue:
            map (
              site:
              site
              // {
                unit = u;
                out = (getInstance u).def.out.${outName}.name;
              }
            ) (scanTokens [ ] outValue)
          ) fixed.${u}.outs
        )
      ) instNames;

      evalEdges = lib.concatMap (
        u:
        lib.mapAttrsToList (hole: p: {
          from = u;
          to = p.instName;
          via = hole;
          kind = "eval";
        }) wiringOne.${u}
        ++ lib.concatLists (
          lib.mapAttrsToList (
            hole: ps:
            map (p: {
              from = u;
              to = p.instName;
              via = hole;
              kind = "eval";
            }) ps
          ) wiringAll.${u}
        )
      ) instNames;

      deployEdges = lib.unique (
        lib.concatMap (
          site:
          lib.optional (site.token.source != site.unit) {
            from = site.unit;
            to = site.token.source;
            # The retrieval, because that is the useful label: it says which
            # resolver this edge needs a backend to have.
            via = site.token.retrieval;
            kind = "deploy";
          }
        ) runtimeSites
      );

      deployDepsOf = u: lib.unique (map (e: e.to) (lib.filter (e: e.from == u) deployEdges));

      phaseOf =
        seen: u:
        if lib.elem u seen then
          throw ("floe link error: runtime-value cycle: " + lib.concatStringsSep " -> " (seen ++ [ u ]))
        else
          let
            deps = deployDepsOf u;
          in
          if deps == [ ] then 0 else 1 + lib.foldl' lib.max 0 (map (phaseOf (seen ++ [ u ])) deps);

      # ---- Output collection -----------------------------------------------
      #
      # Grouped by the emitted signature's `name`, which is what lets a consumer
      # fold every floe's fragment without knowing which floes exist.
      allOutNames = lib.unique (
        lib.concatMap (u: map (sig: sig.name) (lib.attrValues (getInstance u).def.out)) instNames
      );

      outBySigName = lib.genAttrs allOutNames (
        sigName:
        lib.listToAttrs (
          lib.concatMap (
            u:
            let
              matching = lib.filterAttrs (_: sig: sig.name == sigName) (getInstance u).def.out;
            in
            lib.optional (matching != { }) (
              lib.nameValuePair u fixed.${u}.outs.${lib.head (lib.attrNames matching)}
            )
          ) instNames
        )
      );

      # ---- Result and policies ---------------------------------------------

      result = {
        provides = lib.genAttrs instNames (u: fixed.${u}.sealedProvides);
        out = outBySigName;

        # providersOf :: SignatureName -> [{ instName; provideName; value; }]
        providersOf =
          sigName:
          map (p: p // { value = fixed.${p.instName}.sealedProvides.${p.provideName}; }) (
            providersOf sigName
          );

        inputs = lib.genAttrs instNames (u: interfaces.renderInputs (getInstance u).def.inputs);

        graph = {
          nodes = instNames;
          edges = evalEdges ++ deployEdges;
        };
        phases = lib.genAttrs instNames (phaseOf [ ]);

        inherit runtimeSites;

        # The distinct retrievals a backend must implement for this link. A
        # derived view of `runtimeSites`, carried because a preflight wants one
        # lookup rather than a walk.
        runtimeRetrievals = lib.unique (map (s: s.token.retrieval) runtimeSites);

        wiring = {
          one = wiringOne;
          all = wiringAll;
        };
      };

      violations = lib.concatMap (p: p result) policies;
    in
    if nameCollisions != [ ] then
      throw (
        "floe link error: a hole or provide name means more than one signature.\n  - "
        + lib.concatStringsSep "\n  - " nameCollisions
        + "\n\nA reader seeing `requires.<name>` should be able to tell what it is "
        + "without looking it up. Rename one to its signature's `canonicalName`."
      )
    else if singletonBreaches != [ ] then
      throw (
        "floe link error: a singleton floe is instantiated more than once.\n  - "
        + lib.concatStringsSep "\n  - " singletonBreaches
        + "\n\nIts body writes fixed paths instead of keying them by "
        + "`config.floe.name`, so every instance emits the same output. Identical "
        + "values merge without complaint, which would leave you with one of it "
        + "and no error saying so.\n\nEither instantiate it once, or make the "
        + "floe key its output by `config.floe.name` and drop `singleton`."
      )
    else if selfResolutions != [ ] then
      throw (
        "floe link error: a unit does not satisfy its own hole.\n  - "
        + lib.concatStringsSep "\n  - " selfResolutions
        + "\n\nRead the provide directly; it is in scope and needs no link."
      )
    else if violations != [ ] then
      throw ("floe policy violation(s):\n  - " + lib.concatStringsSep "\n  - " violations)
    else
      result;
}

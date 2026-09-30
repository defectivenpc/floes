# link: resolve holes by signature name, tie the graph with lib.fix, seal
# provides against signatures, collect outputs by kind, scan for deferred
# tokens to derive deploy edges and phases, then run policies.
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

      scope ? { },

      # catalogue :: { FloeName -> [SignatureName] }
      # What could fill an unfilled hole. Forced on the error path alone, and
      # a parameter because core knows no floe set.
      catalogue ? { },
    }:
    let
      instNames = lib.attrNames units;
      scopeNames = lib.attrNames scope;

      isFromScope = p: p ? scope;

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
      localProvidersOf = sigName: map (p: removeAttrs p [ "sigName" ]) (providerIndex.${sigName} or [ ]);

      scopeProvidersOf =
        sigName: lib.concatMap (n: lib.optional (scope.${n}.sig.name == sigName) { scope = n; }) scopeNames;

      providersOf =
        sigName:
        let
          here = localProvidersOf sigName;
        in
        if here != [ ] then here else scopeProvidersOf sigName;

      describeProviders =
        ps:
        lib.concatMapStringsSep ", " (
          p:
          if isFromScope p then
            "'${p.scope}' (from the enclosing scope${
              lib.optionalString (scope.${p.scope} ? origin) ": ${scope.${p.scope}.origin}"
            })"
          else
            "'${p.instName}' (as ${p.provideName})"
        ) ps;

      selfResolutions = lib.concatMap (
        u:
        let
          inst = getInstance u;
          holesOf =
            label: decl:
            lib.concatLists (
              lib.mapAttrsToList (
                hole: sig:
                map (
                  p: "floe '${u}' ${label} '${sig.name}' as hole '${hole}' and also provides it (as ${p.provideName})"
                ) (lib.filter (p: !(isFromScope p) && p.instName == u) (localProvidersOf sig.name))
              ) decl
            );
        in
        holesOf "requires" inst.def.requires ++ holesOf "optionally requires" inst.def.requiresOptional
      ) instNames;

      # A binding says which provider a hole means, spelled `<unit>` or
      # `<unit>/<provide>` as `offers` is. It narrows the candidates; the
      # arity rules below then apply to what is left.
      bindingOf = u: hole: (getInstance u).bindings.${hole} or null;

      narrowed =
        u: hole: sig: ps:
        let
          want = bindingOf u hole;
          matches = p: p ? instName && (p.instName == want || "${p.instName}/${p.provideName}" == want);
          kept = lib.filter matches ps;
        in
        if want == null then
          ps
        else if kept == [ ] then
          throw (
            "floe link error: unit '${u}' binds hole '${hole}' to '${want}', which does not "
            + "provide '${sig.name}' here. Provided by: ${describeProviders ps}."
          )
        else if lib.length kept > 1 then
          throw (
            "floe link error: unit '${u}' binds hole '${hole}' to '${want}', which provides "
            + "'${sig.name}' more than once: ${describeProviders kept}. Name the provide too, "
            + "as `<unit>/<provide>`."
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
              + "  In this cluster: ${lib.concatStringsSep ", " instNames}\n"
              + (
                if candidates == [ ] then
                  "  Nothing available provides it."
                else
                  "  Provided by: ${lib.concatStringsSep ", " candidates}. "
                  + "Add one to this cluster, or expose it from another with "
                  + "`lab.clusters.<c>.offers`."
              )
            )
          else if lib.length ps > 1 then
            throw (
              "floe link error: signature '${sig.name}' (required by unit "
              + "'${u}' as hole '${hole}') is provided by multiple units: "
              + "${describeProviders ps}. Say which this unit means with "
              + "`.bind { ${hole} = \"<unit>\"; }`, or remove one."
            )
          else
            lib.head ps
        ) inst.def.requires
      ) (lib.genAttrs instNames getInstance);

      wiringOptional = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (
          hole: sig:
          let
            ps = narrowed u hole sig (providersOf sig.name);
          in
          if lib.length ps > 1 then
            throw (
              "floe link error: signature '${sig.name}' (optionally required by "
              + "unit '${u}' as hole '${hole}') is provided by multiple units: "
              + "${describeProviders ps}. Say which this unit means with "
              + "`.bind { ${hole} = \"<unit>\"; }`, or remove one."
            )
          else
            (if ps == [ ] then null else lib.head ps)
        ) inst.def.requiresOptional
      ) (lib.genAttrs instNames getInstance);

      # The third arity: every provider rather than the one. This link's own
      # units, and never the collecting unit itself — a floe that answers the
      # signature reads `config.floe.provides` and needs no link to do it.
      wiringAll = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (
          _hole: sig: lib.filter (p: p.instName != u) (localProvidersOf sig.name)
        ) inst.def.collects
      ) (lib.genAttrs instNames getInstance);

      localOnly = lib.filterAttrs (_hole: p: p != null && !(isFromScope p));
      fromScopeOnly = lib.filterAttrs (_hole: p: p != null && isFromScope p);

      # ---- Evaluation fixpoint ---------------------------------------------

      sealSig =
        path: sig: v:
        types.checkValue path {
          tag = "record";
          fields = sig.fields;
          name = "signature ${sig.name}";
        } v;

      sealedScope = lib.mapAttrs (
        n: entry:
        let
          sealed = sealSig [ "scope" n ] entry.sig entry.value;
        in
        lib.mapAttrs (
          field: value:
          if types.isLocal entry.sig.fields.${field} then
            throw (
              "floe link error: '${entry.sig.name}.${field}' is local to the link that "
              + "provided it${lib.optionalString (entry ? origin) " (${entry.origin})"}, and this "
              + "is a different one. It names something that exists there — a Service "
              + "address, a namespace, a CRD — and there is no value for it here.\n\n"
              + "Fields of '${entry.sig.name}' that do travel: "
              + (
                let
                  portable = lib.attrNames (lib.filterAttrs (_: t: !(types.isLocal t)) entry.sig.fields);
                in
                if portable == [ ] then "none." else lib.concatStringsSep ", " portable + "."
              )
            )
          else
            value
        ) sealed
      ) scope;

      uncrossable = lib.filter (n: interfaces.isUncrossable scope.${n}.sig) scopeNames;

      fixed = lib.fix (
        self:
        lib.genAttrs instNames (
          u:
          let
            inst = getInstance u;

            valueOf =
              p:
              if isFromScope p then
                sealedScope.${p.scope}
              else
                self.${p.instName}.sealedProvides.${p.provideName};

            resolved =
              lib.mapAttrs (_hole: valueOf) wiringOne.${u}
              // lib.mapAttrs (_hole: p: if p == null then null else valueOf p) wiringOptional.${u};

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
                  evaluated.config.floe.provides.${provideName} or (throw (
                    "floe '${u}': declares provide '${provideName}' (signature "
                    + "'${sig.name}') but its body never defines "
                    + "config.floe.provides.${provideName}"
                  ));
              in
              sealSig [ u "provides" provideName ] sig v
            ) inst.def.provides;
            outs = lib.mapAttrs (
              kName: kind:
              types.checkValue [ u "out" kName ] kind.schema (evaluated.config.floe.out.${kName} or { })
            ) inst.def.out;
          }
        )
      );

      # ---- Graph derivation ------------------------------------------------

      scanTokens =
        v:
        if types.isDeferredToken v then
          [ v ]
        else if builtins.isAttrs v then
          lib.concatMap scanTokens (lib.attrValues v)
        else if builtins.isList v then
          lib.concatMap scanTokens v
        else
          [ ];

      evalEdges = lib.concatMap (
        u:
        lib.mapAttrsToList (hole: p: {
          from = u;
          to = p.instName;
          via = hole;
          kind = "eval";
        }) (localOnly wiringOne.${u})
        ++ lib.concatLists (
          lib.mapAttrsToList (
            hole: p:
            lib.optional (p != null) {
              from = u;
              to = p.instName;
              via = hole;
              kind = "eval";
            }
          ) (localOnly wiringOptional.${u})
        )
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
          u:
          lib.concatMap (
            tok:
            lib.optional (tok ? source && tok.source != u) {
              from = u;
              to = tok.source;
              via = lib.concatStringsSep "." (map toString (tok.path or [ ]));
              kind = "deploy";
            }
          ) (scanTokens fixed.${u}.outs)
        ) instNames
      );

      deployDepsOf = u: lib.unique (map (e: e.to) (lib.filter (e: e.from == u) deployEdges));

      phaseOf =
        seen: u:
        if lib.elem u seen then
          throw ("floe link error: deferred-value cycle: " + lib.concatStringsSep " -> " (seen ++ [ u ]))
        else
          let
            deps = deployDepsOf u;
          in
          if deps == [ ] then 0 else 1 + lib.foldl' lib.max 0 (map (phaseOf (seen ++ [ u ])) deps);

      # ---- Output collection -----------------------------------------------

      allKindNames = lib.unique (
        lib.concatMap (
          u: map (k: (getInstance u).def.out.${k}.name) (lib.attrNames (getInstance u).def.out)
        ) instNames
      );

      outByKind = lib.genAttrs allKindNames (
        kindName:
        lib.foldl' (
          acc: u:
          let
            matching = lib.filterAttrs (_: kind: kind.name == kindName) (getInstance u).def.out;
          in
          if matching == { } then
            acc
          else
            acc // { ${u} = fixed.${u}.outs.${lib.head (lib.attrNames matching)}; }
        ) { } instNames
      );

      # ---- Result and policies ---------------------------------------------

      result = {
        provides = lib.genAttrs instNames (u: fixed.${u}.sealedProvides);
        out = outByKind;

        # providersOf :: SignatureName -> [{ instName; provideName; value; }]
        # Who in this link answers a signature. Its own units only: a provide
        # from the enclosing scope belongs to the link that made it.
        providersOf =
          sigName:
          map (p: p // { value = fixed.${p.instName}.sealedProvides.${p.provideName}; }) (
            localProvidersOf sigName
          );

        inputs = lib.genAttrs instNames (u: interfaces.renderInputs (getInstance u).def.inputs);

        graph = {
          nodes = instNames;
          edges = evalEdges ++ deployEdges;
        };
        phases = lib.genAttrs instNames (phaseOf [ ]);

        wiring = {
          one = lib.mapAttrs (_u: localOnly) wiringOne;
          optional = lib.mapAttrs (_u: localOnly) wiringOptional;

          scope = lib.mapAttrs (u: _: (fromScopeOnly wiringOne.${u}) // (fromScopeOnly wiringOptional.${u})) (
            lib.genAttrs instNames getInstance
          );
        };
      };

      violations = lib.concatMap (p: p result) policies;
    in
    if uncrossable != [ ] then
      throw (
        "floe link error: these provides were offered to this link by its enclosing "
        + "scope, and every field of their signatures is link-local:\n  - "
        + lib.concatMapStringsSep "\n  - " (
          n:
          "'${n}' (signature '${scope.${n}.sig.name}'"
          + lib.optionalString (scope.${n} ? origin) ", from ${scope.${n}.origin}"
          + ")"
        ) uncrossable
        + "\n\nNothing in them would be readable here, so resolving a hole against one "
        + "leaves the consumer with a value it cannot use. These are the promises that "
        + "something is running *in a particular place* — a controller, a webhook, a "
        + "storage class — and the place is not this one."
      )
    else if selfResolutions != [ ] then
      throw (
        "floe link error: a unit does not satisfy its own hole.\n  - "
        + lib.concatStringsSep "\n  - " selfResolutions
        + "\n\nRead `config.floe.provides.<instance>` directly; it is in scope "
        + "and needs no link."
      )
    else if violations != [ ] then
      throw ("floe policy violation(s):\n  - " + lib.concatStringsSep "\n  - " violations)
    else
      result;
}

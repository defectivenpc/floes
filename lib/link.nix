# link: resolve holes by signature name, tie the graph with lib.fix, seal
# provides against signatures, collect outputs by signature name, scan for
# deferred tokens to derive deploy edges and phases, then run policies.
{
  lib,
  types,
  interfaces,
  floeLib,
  refusals,
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
      # in one place, and applied only where a unit gave no `.bind` of its own,
      # so adding a second provider stops being a breaking change to every
      # existing consumer, without making ambiguity silent where no one decided.
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
      # hole and the obvious implementation, scanning every unit's provides per
      # hole, is O(units x holes). Two of them, in fact: `wiringOne` and
      # the self-resolution check each did their own pass. At a thousand of each that
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

      # `sigName` is the index's key and not part of a provider reference:
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
            "optional"
            "collects"
            "provides"
            "out"
          ]
      ) instNames;

      wantedBy =
        u: hole: sig:
        (getInstance u).bindings.${hole} or (defaults.${sig.name} or null);

      # What a hole could resolve to, and whether a deployer said which. Shared
      # by both singular arities, which differ only in what they do with it:
      # `requires` treats one provider as the answer, `optional` treats an
      # unnamed one as not wired.
      selectionFor =
        u: hole: sig:
        let
          want = wantedBy u hole sig;
          ps = providersOf sig.name;
          matches = p: p.instName == want || "${p.instName}/${p.provideName}" == want;
        in
        {
          inherit want ps;
          kept = if want == null then ps else lib.filter matches ps;
          explicit = (getInstance u).bindings ? ${hole};
        };

      tooManyNamed =
        u: hole: sig: s:
        throw (
          "floe link error: '${s.want}' provides '${sig.name}' more than once: "
          + "${describeProviders s.kept}. Name the provide too, as `<unit>/<provide>`."
        );

      bindNamesNothing =
        u: hole: sig: s:
        throw (
          "floe link error: unit '${u}' binds hole '${hole}' to '${s.want}', which does not "
          + "provide '${sig.name}' here. Provided by: ${describeProviders s.ps}."
        );

      narrowed =
        u: hole: sig:
        let
          s = selectionFor u hole sig;
        in
        if s.want == null then
          s.ps
        # A default that names nothing here is not an error: it is a default for
        # a signature this link may not even use. A `.bind` that names nothing is.
        else if s.kept == [ ] then
          if s.explicit then bindNamesNothing u hole sig s else s.ps
        else if lib.length s.kept > 1 then
          tooManyNamed u hole sig s
        else
          s.kept;

      wiringOne = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (
          hole: sig:
          let
            ps = narrowed u hole sig;
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

      # Zero or one, and the asymmetry with `requires` is the point: a provider
      # being present wires nothing. Otherwise adding a floe to a link
      # rewrites another floe's output with nothing saying so, which is the
      # action at a distance that makes `enable` flags frightening once a
      # configuration is large enough that no reader holds all of it.
      #
      # So an unnamed provider is an error rather than a silent no-op, because a
      # deployer who added kanidm and got no OIDC needs to be told why.
      wiringOptional = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (
          hole: sig:
          let
            s = selectionFor u hole sig;
          in
          # Unnamed is unwired. That a provider is nonetheless present is
          # refused by `lib/refusals.nix` rather than thrown from here:
          # a refusal belongs in the preflight with the others, where it is
          # reported rather than escaping from whatever forced it first.
          if s.want == null then
            null
          # A `defaults` entry naming something absent leaves the hole unfilled,
          # which is exactly what this arity is for. An explicit `.bind` naming
          # nothing is still the deployer being wrong about their own link.
          else if s.kept == [ ] then
            (if s.explicit then bindNamesNothing u hole sig s else null)
          else if lib.length s.kept > 1 then
            tooManyNamed u hole sig s
          else
            lib.head s.kept
        ) inst.def.optional
      ) (lib.genAttrs instNames getInstance);

      # The third arity: every provider rather than the one. This link's own
      # units, and never the collecting unit itself: a floe that answers the
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
          inherit (sig) fields;
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
                + "'${sig.name}' is fine from '${u}': the field closes the loop, "
                + "not the hole."
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

            # Both singular arities land in one attrset, because a body wanting
            # "the thing if it is there" should read one place. An unwired
            # optional hole is `null`.
            resolved =
              lib.mapAttrs (hole: p: withheld u p.instName inst.def.requires.${hole} (valueOf p)) wiringOne.${u}
              // lib.mapAttrs (
                hole: p: if p == null then null else withheld u p.instName inst.def.optional.${hole} (valueOf p)
              ) wiringOptional.${u};

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

      # Every deferred token in a value, with the path it sits at.
      #
      # The path is a *list* and not a dotted string, because output keys contain
      # dots: a Kubernetes annotation is `floe.dev/ca-fingerprint`, and a backend
      # that had to split a string there would write to the wrong place.
      scanTokens =
        at: v:
        if types.isDeferredToken v then
          [
            {
              inherit at;
              token = v;
            }
          ]
        # A derivation is an attrset whose `out` is itself, so walking it is a
        # stack overflow, and one `tryEval` cannot catch, which made a package
        # in `out` an uncatchable crash in any link whose sites were read. It
        # holds no token either: a built thing is opaque. ADR 0008.
        else if lib.isDerivation v then
          [ ]
        else if builtins.isAttrs v then
          lib.concatLists (lib.mapAttrsToList (k: scanTokens (at ++ [ k ])) v)
        else if builtins.isList v then
          lib.concatLists (lib.imap0 (i: scanTokens (at ++ [ i ])) v)
        else
          [ ];

      # deferredSites :: [{ unit; out; at; token; }]
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
      deferredSites = lib.concatMap (
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
        # A hole that resolved. An unwired optional one is not an edge, because
        # nothing was read.
        ++ lib.concatMap (
          hole:
          let
            p = wiringOptional.${u}.${hole};
          in
          lib.optional (p != null) {
            from = u;
            to = p.instName;
            via = hole;
            kind = "eval";
          }
        ) (lib.attrNames wiringOptional.${u})
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

      # ---- Cycles ------------------------------------------------------------
      #
      # The strongly-connected components of the eval graph. Derivable here
      # because the eval graph comes from headers, with nothing evaluated when
      # this is known, which is the whole of why ADR 0008 answers RFC 0001's
      # open question 3 with "derived" rather than "declared".
      #
      # Worth exposing rather than only knowing: a floe's output depends on
      # its declared inputs and resolved requires and nothing else, so a unit
      # is a natural memoization unit, unless it sits in a cycle, in which
      # case the cycle is. Naming the cycles is therefore everything core can
      # say about caching without building it, because **every unit not in one
      # is its own cache unit.**
      #
      # It is also what a distribution needs in order to refuse cycles, which
      # some will want and this leaves to them:
      #
      #   policies = [ (r: map (c: "cycle: ${lib.concatStringsSep " -> " c}") r.cycles) ];
      #
      reachable =
        let
          edges = lib.filter (e: e.kind == "eval") evalEdges;
          direct = lib.genAttrs instNames (u: lib.unique (map (e: e.to) (lib.filter (e: e.from == u) edges)));
          step =
            reach: lib.mapAttrs (_: rs: lib.unique (rs ++ lib.concatMap (v: reach.${v} or [ ]) rs)) reach;
        in
        # A path grows by at most one unit per round, so as many rounds as
        # there are units is the closure. Cheaper than detecting the fixed
        # point at the sizes a link has, and it terminates by construction.
        lib.foldl' (acc: _: step acc) direct instNames;

      # A unit is in a cycle exactly when it can reach itself, and its cycle is
      # everything it reaches that reaches it back.
      cycles = lib.unique (
        map (
          u: lib.sort (a: b: a < b) (lib.filter (v: lib.elem u (reachable.${v} or [ ])) reachable.${u})
        ) (lib.filter (u: lib.elem u (reachable.${u} or [ ])) instNames)
      );

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
        ) deferredSites
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
      #
      # Grouped by the emitted signature's `name`, which is what lets a consumer
      # fold every floe's fragment without knowing which floes exist.
      outEntries = lib.concatMap (
        u:
        lib.mapAttrsToList (outName: sig: {
          sigName = sig.name;
          unit = u;
          value = fixed.${u}.outs.${outName};
        }) (getInstance u).def.out
      ) instNames;

      outBySigName = lib.mapAttrs (
        _: es: lib.listToAttrs (map (e: lib.nameValuePair e.unit e.value) es)
      ) (lib.groupBy (e: e.sigName) outEntries);

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

        # Every group of units whose holes resolve to each other. A unit absent
        # from all of them is its own cache unit. ADR 0008.
        inherit cycles;

        inherit deferredSites;

        # The distinct retrievals a backend must implement for this link. A
        # derived view of `deferredSites`, carried because a preflight wants one
        # lookup rather than a walk.
        deferredRetrievals = lib.unique (map (s: s.token.retrieval) deferredSites);

        wiring = {
          one = wiringOne;
          optional = wiringOptional;
          all = wiringAll;
        };
      };

      # Every way this link is refused, in the order they are reported.
      # `lib/refusals.nix` holds them; what stays here is resolution, the
      # fixpoint and the views derived from it.
      refusal = refusals.firstRefusal {
        inherit
          instNames
          getInstance
          providersOf
          describeProviders
          allSurfaces
          selectionFor
          wiringOne
          wiringOptional
          wiringAll
          ;
      };

      violations = lib.concatMap (p: p result) policies;
    in
    if refusal != null then
      throw refusal
    else if violations != [ ] then
      throw ("floe policy violation(s):\n  - " + lib.concatStringsSep "\n  - " violations)
    else
      result;
}

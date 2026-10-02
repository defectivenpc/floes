# link: resolve holes by signature name, tie the graph with lib.fix, seal
# provides against signatures, collect outputs by signature name, scan for
# deferred tokens to derive deploy edges and phases, then run policies.
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
# `rec`, because an inclusion is a floe whose body is a link, so `link` runs
# itself for the units inside one. ADR 0006.
rec {
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

      # synthetic :: [UnitName]
      #
      # Units an inclusion injected to carry its parent's values inward. Passed
      # rather than detected from a name prefix, because a deployer is entitled
      # to call a unit anything and a prefix would quietly swallow it. They are
      # an implementation device, so every view below is computed as if the
      # value had simply arrived.
      synthetic ? [ ],

      # withinInclusion :: UnitName | null
      #
      # Set when this link is the body of an inclusion, and read on the
      # unfilled-hole error path alone. The mistake that error is usually
      # reporting, for an inclusion, is a hole the author forgot to declare —
      # and the fix is a line on the inclusion rather than a unit in the link,
      # which is worth saying since nothing else here would.
      withinInclusion ? null,
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
            "optional"
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

      # A unit answering its own hole. Both singular arities, because the
      # argument is the same for each: an otel-collector that provided
      # TRACE_INGEST would resolve its own trace backend to itself and export
      # into its own receiver.
      selfResolutions = lib.concatMap (
        u:
        let
          inst = getInstance u;
          onSurface =
            surface: verb:
            lib.concatLists (
              lib.mapAttrsToList (
                hole: sig:
                map (
                  p: "floe '${u}' ${verb} '${sig.name}' as hole '${hole}' and also provides it (as ${p.provideName})"
                ) (lib.filter (p: p.instName == u) (providersOf sig.name))
              ) inst.def.${surface}
            );
        in
        onSurface "requires" "requires" ++ onSurface "optional" "optionally requires"
      ) instNames;

      # One name on two singular surfaces of one floe. They resolve into one
      # `requires` attrset, so without this one of them is silently dropped.
      surfaceCollisions = lib.concatMap (
        u:
        let
          def = (getInstance u).def;
        in
        map (h: "floe '${u}' declares hole '${h}' in both `requires` and `optional`") (
          lib.intersectLists (lib.attrNames def.requires) (lib.attrNames def.optional)
        )
      ) instNames;

      # An optional hole nobody named, in a link that has a provider for it. The
      # no-op would be defensible and is not what a deployer who added the
      # provider expects, so it is an error that names the candidate.
      unnamedOptionals = lib.concatMap (
        u:
        let
          inst = getInstance u;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            hole: sig:
            let
              s = selectionFor u hole sig;
            in
            lib.optional (s.want == null && s.ps != [ ]) {
              inherit u hole sig;
              candidate = (lib.head s.ps).instName;
              describe = describeProviders s.ps;
            }
          ) inst.def.optional
        )
      ) instNames;

      # A `.bind` naming a collected hole. Silently ignored until now, because
      # `wiringAll` takes every provider and never consulted a binding — so a
      # deployer who wrote one believed it did something. A collection's arity is
      # every provider; there is nothing there to choose.
      collectBindings = lib.concatMap (
        u:
        let
          inst = getInstance u;
        in
        map (hole: "unit '${u}' binds hole '${hole}', which collects '${inst.def.collects.${hole}.name}'") (
          lib.filter (h: inst.def.collects ? ${h}) (lib.attrNames inst.bindings)
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
              + lib.optionalString (withinInclusion != null) (
                "\n\nThis link is the body of inclusion '${withinInclusion}'. If "
                + "'${sig.name}' is meant to come from outside it, declare it there — "
                + "`requires.${sig.canonicalName} = <${sig.name}>` — and whatever links "
                + "'${withinInclusion}' will fill it."
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
      # merely being present wires nothing. Otherwise adding a floe to a link
      # rewrites another floe's output with nothing saying so, which is the
      # action at a distance that makes `enable` flags frightening once a
      # configuration is large enough that nobody reads all of it.
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
          # refused, as `unnamedOptionals` below, rather than thrown from here:
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
      # units, and never the collecting unit itself — a floe that answers the
      # signature reads its own provide and needs no link to do it.
      wiringAll = lib.mapAttrs (
        u: inst:
        lib.mapAttrs (_hole: sig: lib.filter (p: p.instName != u) (providersOf sig.name)) inst.def.collects
      ) (lib.genAttrs instNames getInstance);

      # ---- Compatibility ----------------------------------------------------
      #
      # Resolution matches a signature by `name`, a bare string. Nothing used to
      # compare the shapes behind it, so two definitions of one name linked
      # cleanly and then failed where the value was read —
      # `attribute 'port' missing`, naming no floe and catchable by nothing.
      # That is the error a third-party floe pinning an older copy of a
      # signature gets, and it is why this check exists. ADR 0007.
      #
      # Header-only, so it costs nothing per value and reports before any body
      # evaluates. Both facts it needs are in the declarations: which provide
      # answered, and what each side declared.
      incompatible =
        u: hole: verb: sig: p:
        let
          provided = (getInstance p.instName).def.provides.${p.provideName};
          ms = types.mismatches [ ] provided.shape sig.shape;
        in
        lib.optional (ms != [ ]) (
          "'${p.instName}' provides '${provided.name}' (as ${p.provideName}) but cannot answer "
          + "what '${u}' ${verb} as hole '${hole}':\n      - "
          + lib.concatStringsSep "\n      - " ms
        );

      incompatibilities = lib.concatMap (
        u:
        let
          def = (getInstance u).def;
        in
        lib.concatLists (
          lib.mapAttrsToList (hole: p: incompatible u hole "requires" def.requires.${hole} p) wiringOne.${u}
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            hole: p: if p == null then [ ] else incompatible u hole "optionally requires" def.optional.${hole} p
          ) wiringOptional.${u}
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            hole: ps: lib.concatMap (incompatible u hole "collects" def.collects.${hole}) ps
          ) wiringAll.${u}
        )
      ) instNames;

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

      # ---- Inclusions -------------------------------------------------------

      inclusionOf = u: (getInstance u).def.inclusion;
      isInclusion = u: inclusionOf u != null;

      # A unit name inside an inclusion, as the parent sees it. A backend wants
      # one bucket, so an inclusion's units appear beside the parent's own
      # rather than nested inside them.
      qualify = u: n: "${u}/${n}";

      isSynthetic = n: lib.elem n synthetic;

      # An outer value, offered to the units inside as an ordinary provider.
      #
      # That is the whole of how a parent fills an inner hole, and the reason
      # this is not `scope` again: not a second resolution path consulted when
      # the first one fails, but a unit in the link like any other, with a real
      # eval edge pointing at it. Resolution gained nothing to special-case.
      outerPrefix = "outer:";

      outerUnit =
        sig: value:
        (floeLib.mkFloe {
          name = "outer";
          summary = "A value this link was given from outside it.";
          provides.${sig.canonicalName} = sig;
          body = _: { provides.${sig.canonicalName} = value; };
        }).instantiate
          { };

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
            # The link an inclusion is, or null. Every outer hole it declared
            # becomes a unit inside providing what the parent resolved it to,
            # so the units inside resolve against one set of providers by one
            # rule.
            inner =
              let
                incl = inst.def.inclusion;

                fromOuter =
                  surface:
                  lib.listToAttrs (
                    lib.concatMap (
                      hole:
                      lib.optional (resolved.${hole} != null) (
                        lib.nameValuePair "${outerPrefix}${hole}" (outerUnit inst.def.${surface}.${hole} resolved.${hole})
                      )
                    ) (lib.attrNames inst.def.${surface})
                  );

                # One per contributor, so the collector inside sees the same
                # fan-in the parent did rather than one merged value.
                fromOuterCollections = lib.listToAttrs (
                  lib.concatLists (
                    lib.mapAttrsToList (
                      hole: byUnit:
                      lib.mapAttrsToList (
                        contributor: value:
                        lib.nameValuePair "${outerPrefix}${hole}:${contributor}" (outerUnit inst.def.collects.${hole} value)
                      ) byUnit
                    ) collected
                  )
                );
              in
              if incl == null then
                null
              else
                let
                  injected = fromOuter "requires" // fromOuter "optional" // fromOuterCollections;
                in
                link {
                  synthetic = lib.attrNames injected;
                  units =
                    incl.units {
                      inputs = inst.inputsChecked;
                      requires = resolved;
                      collects = collected;
                      floe = {
                        name = u;
                        mkDeferred = floeLib.mkDeferredFor u;
                      };
                    }
                    // injected;
                  inherit (incl) defaults policies;
                  inherit catalogue;
                  withinInclusion = u;
                };

            # What an inclusion offers outward: one of its units' provides,
            # named by `exports` and sealed to the signature it declared — which
            # is how a field meaningful only inside stays inside.
            exported = lib.mapAttrs (
              exportName: ref:
              let
                parts = lib.splitString "/" ref;
                iu = lib.head parts;
                ps =
                  inner.provides.${iu} or (throw (
                    "inclusion '${u}': exports '${exportName}' from unit '${iu}', which is not "
                    + "in it. It holds: ${lib.concatStringsSep ", " (lib.attrNames inner.provides)}."
                  ));
                names = lib.attrNames ps;
              in
              if lib.length parts > 1 then
                ps.${lib.elemAt parts 1} or (throw (
                  "inclusion '${u}': exports '${exportName}' from '${ref}', and '${iu}' has no "
                  + "provide '${lib.elemAt parts 1}'. It provides: "
                  + "${lib.concatStringsSep ", " names}."
                ))
              else if lib.length names == 1 then
                lib.head (lib.attrValues ps)
              else
                throw (
                  "inclusion '${u}': exports '${exportName}' from '${iu}', which provides "
                  + "${toString (lib.length names)} things (${lib.concatStringsSep ", " names}). "
                  + "Name which, as `<unit>/<provide>`."
                )
            ) (inst.def.inclusion.exports or { });

            evaluated =
              if inst.def.inclusion != null then
                {
                  provides = exported;
                  # An inclusion emits nothing of its own; its units' output
                  # propagates to the parent. One mechanism, not two.
                  out = { };
                }
              else
                floeLib.evalFloe {
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
      # dots — a Kubernetes annotation is `floe.dev/ca-fingerprint`, and a backend
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
        # stack overflow — and one `tryEval` cannot catch, which made a package
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
        if isInclusion u then
          # Already flattened one level down, so re-qualifying is all that is
          # left. `token.source` needs it too, and only when the token was
          # minted inside: `mkDeferred` binds `source` at body-eval time, when
          # the inner link cannot know it will be included. A token that came
          # *through* the inclusion from outside already names a unit the parent
          # knows, and qualifying that would invent a node.
          let
            innerNodes = fixed.${u}.inner.graph.nodes;
          in
          map (
            site:
            site
            // {
              unit = qualify u site.unit;
              token = site.token // {
                source =
                  if lib.elem site.token.source innerNodes then qualify u site.token.source else site.token.source;
              };
            }
          ) fixed.${u}.inner.deferredSites
        else
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

      # An edge to a synthetic unit stands for a value the parent supplied, and
      # the parent emits that edge itself against its own hole. Keeping this one
      # too would say the same thing twice, in terms of a node nothing else
      # mentions.
      evalEdges = lib.filter (e: !(isSynthetic e.to)) (
        lib.concatMap (
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
        ) instNames
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
      # fold every floe's fragment without knowing which floes exist — and, with
      # an inclusion in the link, without knowing how deep any of them sit.
      # A synthetic unit declares no `out`, so it contributes nothing here and
      # needs no filtering — the same is true of `deferredSites`.
      outEntries = lib.concatMap (
        u:
        if isInclusion u then
          lib.concatLists (
            lib.mapAttrsToList (
              sigName: byUnit:
              lib.mapAttrsToList (leaf: value: {
                inherit sigName value;
                unit = qualify u leaf;
              }) byUnit
            ) fixed.${u}.inner.out
          )
        else
          lib.mapAttrsToList (outName: sig: {
            sigName = sig.name;
            unit = u;
            value = fixed.${u}.outs.${outName};
          }) (getInstance u).def.out
      ) instNames;

      outBySigName = lib.mapAttrs (
        _: es: lib.listToAttrs (map (e: lib.nameValuePair e.unit e.value) es)
      ) (lib.groupBy (e: e.sigName) outEntries);

      # Every unit that emits, at any depth: what `phases` is keyed by, because
      # an inclusion is not a thing that applies — its units are.
      #
      # Recursing through each inner link's *leaves* and not its nodes, which is
      # the whole of the difference once there are two levels: an inner link's
      # nodes include its own inclusions, and those are not leaves either. At
      # one level the two sets coincide, which is why this took a nested test.
      leafNames = lib.concatMap (
        u:
        if isSynthetic u then
          [ ]
        else if isInclusion u then
          map (qualify u) fixed.${u}.inner.leaves
        else
          [ u ]
      ) instNames;

      # Every unit at every level, inclusions included — an inclusion is a node
      # because the edge into it is a real fact about its own hole, and an inner
      # edge may name one, so leaving it out would dangle.
      nodeNames = lib.concatMap (
        u:
        if isSynthetic u then
          [ ]
        else if isInclusion u then
          [ u ] ++ map (qualify u) fixed.${u}.inner.graph.nodes
        else
          [ u ]
      ) instNames;

      # The eval edges from inside an inclusion, and only those. A deploy edge is
      # derived from a token in output, `deferredSites` is already flattened to
      # every depth, and `deployEdges` below derives from that — so taking the
      # inner ones too would duplicate every one of them.
      #
      # It would also get them wrong: a token that reached an inner unit from
      # outside makes an inner deploy edge pointing at a unit the inner link
      # does not contain, so qualifying both ends would invent a node. Hence
      # qualifying only what the inner link actually holds, here as well.
      innerEdges = lib.concatMap (
        u:
        if isInclusion u then
          let
            innerNodes = fixed.${u}.inner.graph.nodes;
            rename = n: if lib.elem n innerNodes then qualify u n else n;
          in
          map (
            e:
            e
            // {
              from = rename e.from;
              to = rename e.to;
            }
          ) (lib.filter (e: e.kind == "eval") fixed.${u}.inner.graph.edges)
        else
          [ ]
      ) instNames;

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

        # An inclusion is a node and so are its units: the edge into one is a
        # real fact about the inclusion's own hole, and the edges between its
        # units are real facts about them. So the graph is hierarchical where
        # the link is, and flat everywhere else.
        # Every unit that emits, at any depth, which is what a parent recurses
        # through when this link is the body of one of its inclusions.
        leaves = leafNames;

        graph = {
          nodes = lib.unique nodeNames;
          edges = evalEdges ++ innerEdges ++ deployEdges;
        };

        # Keyed by what emits, which after an inclusion is its units rather than
        # it. Deploy edges are derived from tokens in output, and output comes
        # from leaves, so this needs no special case beyond the flattening.
        phases = lib.genAttrs leafNames (phaseOf [ ]);

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
    else if surfaceCollisions != [ ] then
      throw (
        "floe link error: a hole name is declared on two singular surfaces.\n  - "
        + lib.concatStringsSep "\n  - " surfaceCollisions
        + "\n\nBoth resolve into `requires`, so one of them would be dropped with "
        + "nothing saying which. Pick the arity the floe means: `requires` if it "
        + "cannot work without the thing, `optional` if it can."
      )
    else if collectBindings != [ ] then
      throw (
        "floe link error: a binding names a collected hole.\n  - "
        + lib.concatStringsSep "\n  - " collectBindings
        + "\n\nA collection's arity is every provider in the link, so there is "
        + "nothing for a binding to choose, and this one was being ignored. Remove "
        + "it, or declare the hole `requires` or `optional` if exactly one provider "
        + "is what the floe meant."
      )
    else if selfResolutions != [ ] then
      throw (
        "floe link error: a unit does not satisfy its own hole.\n  - "
        + lib.concatStringsSep "\n  - " selfResolutions
        + "\n\nRead the provide directly; it is in scope and needs no link."
      )
    else if unnamedOptionals != [ ] then
      throw (
        "floe link error: an optional hole has a provider that nobody named.\n  - "
        + lib.concatMapStringsSep "\n  - " (
          o:
          "unit '${o.u}' optionally requires '${o.sig.name}' as hole '${o.hole}', provided "
          + "here by ${o.describe}"
        ) unnamedOptionals
        + "\n\nAn optional hole is never wired by a provider merely being present, so "
        + "nothing is connected and the unit would quietly run without it. That is what "
        + "keeps adding a floe from silently changing another floe's output.\n\n"
        + "Wire it for one unit with `.bind { "
        + "${(lib.head unnamedOptionals).hole} = \"${(lib.head unnamedOptionals).candidate}\"; }`, "
        + "or for every unit with `link { defaults.${(lib.head unnamedOptionals).sig.name} = "
        + "\"${(lib.head unnamedOptionals).candidate}\"; }`."
      )
    else if incompatibilities != [ ] then
      throw (
        "floe link error: a provider cannot answer the signature a unit asked for.\n  - "
        + lib.concatStringsSep "\n  - " incompatibilities
        + "\n\nResolution matches a signature by name, so two definitions of one name "
        + "link and then fail wherever the value is read, naming no floe. Widen the "
        + "provider's signature, or narrow the requirer's to the fields it uses."
      )
    else if violations != [ ] then
      throw ("floe policy violation(s):\n  - " + lib.concatStringsSep "\n  - " violations)
    else
      result;
}

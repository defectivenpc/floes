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
# `rec`, because an inclusion is a floe whose body is a link, so `link` runs
# itself for the units inside one. ADR 0006.
rec {
  inherit candidatesFor;

  # link: what a deployer calls.
  #
  # A gate in front of `linkWith`, which carries the two arguments the linker
  # passes to itself when an inclusion's body is linked. They were public and
  # documented as internal, which meant a deployer could declare units
  # synthetic and have them vanish from `out`, `phases` and the graph, with no
  # error, since every view is computed as if a synthetic unit's value had
  # arrived on its own.
  link =
    args:
    let
      forged = lib.intersectLists [ "synthetic" "withinInclusion" ] (lib.attrNames args);
    in
    if forged != [ ] then
      throw (
        "floe link error: ${lib.concatMapStringsSep ", " (a: "`${a}`") forged} is not an "
        + "argument to `link`. It is how the linker tells itself that a link is the body "
        + "of an inclusion, and a value from outside is carrying a hole inward. A floe "
        + "includes a link by giving `mkFloe` a `units` function."
      )
    else
      linkWith args;

  # The linker, including the arguments it passes to itself. `link` below is
  # what a deployer calls.
  linkWith =
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

      # synthetic :: { UnitName -> { hole; signature; } }
      #
      # Units an inclusion injected to carry its parent's values inward. Passed
      # rather than detected from a name prefix, because a deployer is entitled
      # to call a unit anything and a prefix would quietly swallow it. They are
      # an implementation device, so every view below is computed as if the
      # value had simply arrived.
      #
      # Each carries the hole it came from, so that a hole the inclusion
      # declared and nothing inside reads can be named in the error rather than
      # recovered from a unit name.
      synthetic ? { },

      # withinInclusion :: UnitName | null
      #
      # Set when this link is the body of an inclusion, and read on the
      # unfilled-hole error path alone. The mistake that error is usually
      # reporting, for an inclusion, is a hole the author forgot to declare,
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
              + lib.optionalString (withinInclusion != null) (
                "\n\nThis link is the body of inclusion '${withinInclusion}'. If "
                + "'${sig.name}' is meant to come from outside it, declare it there as "
                + "`requires.${sig.canonicalName} = <${sig.name}>`, and whatever links "
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

      # ---- Inclusions -------------------------------------------------------

      inclusionOf = u: (getInstance u).def.inclusion;
      isInclusion = u: inclusionOf u != null;

      # Whether a unit has an implementation of its own, which is independent of
      # whether it includes one: a floe may do both, and the two halves meet in
      # `evaluated` below. MixML's closure property, ADR 0006.
      defines =
        u:
        let
          def = (getInstance u).def;
        in
        def.body != null || def.modules != [ ];

      # A unit name inside an inclusion, as the parent sees it. A backend wants
      # one bucket, so an inclusion's units appear beside the parent's own
      # rather than nested inside them.
      qualify = u: n: "${u}/${n}";

      isSynthetic = n: synthetic ? ${n};

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
            # Every outer hole this inclusion declared, as what the inner link
            # needs to know about it: the value, the signature the boundary
            # allows, and the hole it came from so an error can name it.
            injectedMeta =
              let
                fromSurface =
                  surface:
                  lib.listToAttrs (
                    lib.concatMap (
                      hole:
                      lib.optional (resolved.${hole} != null) (
                        lib.nameValuePair "${outerPrefix}${hole}" {
                          inherit hole;
                          sig = inst.def.${surface}.${hole};
                          value = resolved.${hole};
                        }
                      )
                    ) (lib.attrNames inst.def.${surface})
                  );

                # One per contributor, so the collector inside sees the same
                # fan-in the parent did rather than one merged value.
                fromCollections = lib.listToAttrs (
                  lib.concatLists (
                    lib.mapAttrsToList (
                      hole: byUnit:
                      lib.mapAttrsToList (contributor: value: {
                        name = "${outerPrefix}${hole}:${contributor}";
                        value = {
                          inherit hole value;
                          sig = inst.def.collects.${hole};
                        };
                      }) byUnit
                    ) collected
                  )
                );
              in
              if inst.def.inclusion == null then
                { }
              else
                fromSurface "requires" // fromSurface "optional" // fromCollections;

            # The units inside, hoisted so their *headers* are reachable:
            # `exports` is checked against them below, and that cannot happen
            # in the preflight because `units` is a function of this
            # inclusion's resolved holes, so there is nothing to read until the
            # fixpoint has resolved them.
            innerUnits =
              if inst.def.inclusion == null then
                { }
              else
                inst.def.inclusion.units {
                  inputs = inst.inputsChecked;
                  requires = resolved;
                  collects = collected;
                  floe = {
                    name = u;
                    mkDeferred = floeLib.mkDeferredFor u;
                  };
                }
                // lib.mapAttrs (_: i: outerUnit i.sig i.value) injectedMeta;

            # The link an inclusion is, or null. Every outer hole it declared
            # becomes a unit inside providing what the parent resolved it to,
            # so the units inside resolve against one set of providers by one
            # rule.
            inner =
              if inst.def.inclusion == null then
                null
              else
                linkWith {
                  units = innerUnits;
                  synthetic = lib.mapAttrs (_: i: {
                    inherit (i) hole;
                    signature = i.sig.name;
                  }) injectedMeta;
                  inherit (inst.def.inclusion) policies;
                  inherit catalogue;
                  withinInclusion = u;

                  # An injected unit is a provider the deployer already named:
                  # it exists *because* the parent resolved the hole it carries,
                  # and for an optional hole that resolution is the decision
                  # ADR 0009 requires. Without this, a parent filling an
                  # inclusion's optional hole produced an inner link refusing
                  # it for having a provider no one named — the decision made
                  # one level up, invisible one level down.
                  #
                  # The inclusion's own `defaults` win, because an author
                  # saying which provider a hole means inside is saying it
                  # about the units inside.
                  defaults =
                    lib.mapAttrs' (unitName: i: lib.nameValuePair i.sig.name unitName) injectedMeta
                    // inst.def.inclusion.defaults;
                };

            # What an inclusion offers outward: one of its units' provides,
            # named by `exports` and sealed to the signature it declared, which
            # is how a field meaningful only inside stays inside.
            exported = lib.mapAttrs (
              exportName: ref:
              let
                parts = lib.splitString "/" ref;
                iu = lib.head parts;

                # The signature the *author* declared for this export, not the
                # inner provide's. The choice is what `mayExport` is about.
                sigOfExport = inst.def.provides.${exportName};
                ps =
                  inner.provides.${iu} or (throw (
                    "inclusion '${u}': exports '${exportName}' from unit '${iu}', which is not "
                    + "in it. It holds: ${lib.concatStringsSep ", " (lib.attrNames inner.provides)}."
                  ));
                names = lib.attrNames ps;
              in
              if !(sigOfExport.mayExport or true) then
                throw (
                  "inclusion '${u}': exports '${exportName}' as '${sigOfExport.name}', which "
                  + "cannot cross a boundary. It describes something that exists in exactly one "
                  + "place, so a peer given it would hold a reference to something that is not "
                  + "there. Keep it inside, or export a signature that says what a reader "
                  + "outside can actually use."
                )
              else if lib.length parts > 1 then
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

            # And that each export really is a *narrowing* of what it re-exports.
            #
            # An export signature's whole job is to promise less than the one
            # inside, which is what keeps a field meaningful only in here from
            # leaving. One that promises *more* used to surface where a peer
            # read the field that was not there, the same failure compatibility
            # exists to prevent, reintroduced by the thing that replaced
            # `T.local`. `interfaces.narrows` is the relation, pointed inward.
            exportWidenings = lib.concatLists (
              lib.mapAttrsToList (
                exportName: ref:
                let
                  parts = lib.splitString "/" ref;
                  iu = lib.head parts;
                  provs = (innerUnits.${iu} or null).def.provides or { };
                  provideName =
                    if lib.length parts > 1 then
                      lib.elemAt parts 1
                    else if lib.length (lib.attrNames provs) == 1 then
                      lib.head (lib.attrNames provs)
                    else
                      null;
                  innerSig = if provideName == null then null else provs.${provideName} or null;
                  declared = inst.def.provides.${exportName};
                  # A ref naming nothing, or a unit providing several things, is
                  # reported by `exported` with a better message than this could
                  # manage. Nothing to say about narrowing until there is a
                  # signature on both sides.
                  added = if innerSig == null then [ ] else interfaces.narrows innerSig declared;
                in
                map (
                  m:
                  "inclusion '${u}': exports '${exportName}' as '${declared.name}', which promises "
                  + "more than the '${innerSig.name}' it re-exports from '${ref}': ${m}"
                ) added
              ) (inst.def.inclusion.exports or { })
            );

            # The export half: what the units inside offer outward, once the
            # narrowing check has passed.
            exportedChecked =
              if exportWidenings != [ ] then
                throw (
                  "floe link error: an export promises more than what it "
                  + "re-exports.\n  - "
                  + lib.concatStringsSep "\n  - " exportWidenings
                  + "\n\nAn export signature exists to promise *less* than the one inside, "
                  + "which is what keeps a value meaningful only in there from leaving. One "
                  + "promising more is a field a peer can ask for and nothing can answer."
                )
              else
                exported;

            # The body half, or nothing. A floe that only includes has no body
            # to run, and one that only defines has nothing to export.
            defined =
              if defines u then
                floeLib.evalFloe {
                  instance = inst;
                  instName = u;
                  resolvedRequires = resolved;
                  resolvedCollects = collected;
                }
              else
                {
                  provides = { };
                  out = { };
                };

            # A provide answered twice, once by an export and once by the body.
            # Refused rather than resolved, for the reason two providers of one
            # signature are: the two values may agree today and the deployer
            # would never learn which they got.
            doubleAnswered = lib.intersectLists (lib.attrNames exportedChecked) (
              lib.attrNames defined.provides
            );

            evaluated =
              if doubleAnswered != [ ] then
                throw (
                  "floe link error: floe '${u}' answers "
                  + lib.concatMapStringsSep ", " (p: "'${p}'") doubleAnswered
                  + " twice, once by `exports` and once from its body. A provide comes "
                  + "from one place: drop the export, or stop defining it in the body."
                )
              else
                {
                  # Both halves, and the inner units' own output propagates to
                  # the parent separately, keyed by `<thisFloe>/<innerUnit>`.
                  provides = exportedChecked // defined.provides;
                  inherit (defined) out;
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
      # Spanning the nesting, like `phases` and unlike `wiring`: a cycle inside
      # an inclusion is a cache-unit fact the parent needs too.
      reachable =
        let
          edges = lib.filter (e: e.kind == "eval") (evalEdges ++ innerEdges);
          direct = lib.genAttrs nodeNames (u: lib.unique (map (e: e.to) (lib.filter (e: e.from == u) edges)));
          step =
            reach: lib.mapAttrs (_: rs: lib.unique (rs ++ lib.concatMap (v: reach.${v} or [ ]) rs)) reach;
        in
        # A path grows by at most one unit per round, so as many rounds as
        # there are units is the closure. Cheaper than detecting the fixed
        # point at the sizes a link has, and it terminates by construction.
        lib.foldl' (acc: _: step acc) direct nodeNames;

      # A unit is in a cycle exactly when it can reach itself, and its cycle is
      # everything it reaches that reaches it back.
      cycles = lib.unique (
        map (
          u: lib.sort (a: b: a < b) (lib.filter (v: lib.elem u (reachable.${v} or [ ])) reachable.${u})
        ) (lib.filter (u: lib.elem u (reachable.${u} or [ ])) nodeNames)
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
      # fold every floe's fragment without knowing which floes exist, and with
      # an inclusion in the link, without knowing how deep any of them sit.
      # A synthetic unit declares no `out`, so it contributes nothing here and
      # needs no filtering, and the same is true of `deferredSites`.
      # A floe that includes *and* defines contributes both: its units' output
      # under `<thisFloe>/<innerUnit>`, and its own under its own name. The keys
      # differ by construction, so the two cannot collide and neither needs to
      # know about the other.
      outEntries = lib.concatMap (
        u:
        (lib.optionals (isInclusion u) (
          lib.concatLists (
            lib.mapAttrsToList (
              sigName: byUnit:
              lib.mapAttrsToList (leaf: value: {
                inherit sigName value;
                unit = qualify u leaf;
              }) byUnit
            ) fixed.${u}.inner.out
          )
        ))
        ++ lib.mapAttrsToList (outName: sig: {
          sigName = sig.name;
          unit = u;
          value = fixed.${u}.outs.${outName};
        }) (getInstance u).def.out
      ) instNames;

      outBySigName = lib.mapAttrs (
        _: es: lib.listToAttrs (map (e: lib.nameValuePair e.unit e.value) es)
      ) (lib.groupBy (e: e.sigName) outEntries);

      # Every unit that emits, at any depth: what `phases` is keyed by, because
      # an inclusion is not a thing that applies; its units are.
      #
      # Recursing through each inner link's *leaves* and not its nodes, which is
      # the whole of the difference once there are two levels: an inner link's
      # nodes include its own inclusions, and those are not leaves either. At
      # one level the two sets coincide, which is why this took a nested test.
      # A floe that includes and also emits is a leaf as well as a node: its own
      # fragment applies, and so do its units'. One that only includes is not,
      # which is why this cannot be unconditional.
      leafNames = lib.concatMap (
        u:
        if isSynthetic u then
          [ ]
        else if isInclusion u then
          map (qualify u) fixed.${u}.inner.leaves ++ lib.optional ((getInstance u).def.out != { }) u
        else
          [ u ]
      ) instNames;

      # Every unit at every level, inclusions included: an inclusion is a node
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

      # What each unit is an instance of, at any depth.
      #
      # The one per-unit fact a parent cannot derive for itself: an inner unit's
      # *definition* is not reachable through the inclusion holding it, by
      # design, and a consumer with a per-floe rule — "every floe declares the
      # images its manifests pull" — needs the name to find the declaration it
      # is checking against. A unit name is the deployer's and says nothing
      # about which floe it is.
      floeNames = lib.foldl' lib.mergeAttrs { } (
        map (
          u:
          if isSynthetic u then
            { }
          else
            {
              ${u} = (getInstance u).def.name;
            }
            // lib.optionalAttrs (isInclusion u) (
              lib.mapAttrs' (n: v: lib.nameValuePair (qualify u n) v) fixed.${u}.inner.floeNames
            )
        ) instNames
      );

      # The eval edges from inside an inclusion, and only those. A deploy edge is
      # derived from a token in output, `deferredSites` is already flattened to
      # every depth, and `deployEdges` below derives from that, so taking the
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

      # An inclusion's inner wiring, under the qualified names its output, its
      # nodes and its edges already arrive under.
      #
      # `wiring` answers "which provider filled this hole", and a unit inside
      # an inclusion had no entry at all: the parent's `wiring.one.<inclusion>`
      # describes the inclusion's own holes, not its units'. A consumer that
      # derives anything per-unit from a resolution — an installer deriving one
      # component's dependency on another's — lost it for every unit inside.
      #
      # Both halves are qualified, for the reason `innerEdges` qualifies both
      # ends of an edge: the consumer is an inner unit, and so is the provider.
      #
      # A synthetic unit appears on neither side. Answering a hole, it stands
      # for a value the parent supplied, and the parent's own entry against its
      # own hole says that already in terms of a node that exists — exactly why
      # the edge to one is dropped too. Keyed as a consumer, it is a unit
      # nothing else mentions with no holes to report. Membership in the inner
      # link's nodes is the test on both sides, because the synthetic units are
      # the only units that set excludes. For `collects` the list is filtered
      # rather than the hole dropped, since a collection can be answered from
      # inside and outside at once.
      #
      # exportOriginOf :: UnitName -> ProvideName -> { instName; provideName; }
      #
      # Which unit actually *implements* a provision, when the unit providing it
      # is an inclusion re-exporting from inside. `exports` names that unit, so
      # the answer is written down — it was just not reachable from the result,
      # which is all a consumer gets.
      #
      # It matters for anything that reasons about what a provision is backed
      # by rather than who promises it. A backend deriving install order from
      # the link graph asks the provider for its artifacts; an inclusion that
      # only includes has none of its own, so the dependency silently had no
      # target and the edge vanished. The consumer was then free to be
      # installed before the thing it needs, with nothing in the graph saying
      # otherwise. ADR 0013.
      #
      # One level of qualification reaches every depth, because the inner
      # result answers for its own inclusions — the same argument
      # `innerWiringOf` below makes.
      exportOriginOf =
        u: provideName:
        let
          ref = (inclusionOf u).exports.${provideName} or null;
          parts = lib.splitString "/" ref;
          innerUnit = lib.head parts;
          innerInst = fixed.${u}.innerUnits.${innerUnit} or null;

          innerProvides = innerInst.def.provides or { };
          innerProvide =
            if lib.length parts > 1 then
              lib.elemAt parts 1
            else if lib.length (lib.attrNames innerProvides) == 1 then
              lib.head (lib.attrNames innerProvides)
            else
              null;

          deeper =
            if innerInst != null && (innerInst.def.inclusion or null) != null && innerProvide != null then
              fixed.${u}.inner.exportOriginOf innerUnit innerProvide
            else
              null;
        in
        if ref == null then
          {
            instName = u;
            inherit provideName;
          }
        else if deeper != null then
          {
            instName = qualify innerUnit deeper.instName;
            inherit (deeper) provideName;
          }
        else
          {
            instName = innerUnit;
            provideName = if innerProvide != null then innerProvide else provideName;
          };

      # Every provider reference, told what backs it. `instName` is untouched —
      # it is who promised the value, which is what resolution and every error
      # message mean by a provider — and `backedBy` is where the thing lives.
      withBacking =
        p:
        if p == null || !(isInclusion p.instName) then
          p
        else
          let
            origin = exportOriginOf p.instName p.provideName;
          in
          p
          // {
            backedBy = qualify p.instName origin.instName;
            backedProvide = origin.provideName;
          };

      # One level of qualification reaches every depth: the inner result's own
      # `wiring` has already been through this.
      innerWiringOf =
        u:
        let
          innerNodes = fixed.${u}.inner.graph.nodes;
          held = p: p != null && lib.elem p.instName innerNodes;
          lift =
            p:
            p
            // {
              instName = qualify u p.instName;
            }
            // lib.optionalAttrs (p ? backedBy) { backedBy = qualify u p.backedBy; };
          byUnit =
            f: byName:
            lib.mapAttrs' (n: holes: lib.nameValuePair (qualify u n) (f holes)) (
              lib.filterAttrs (n: _: lib.elem n innerNodes) byName
            );
          inner = fixed.${u}.inner.wiring;
        in
        {
          one = byUnit (holes: lib.mapAttrs (_: lift) (lib.filterAttrs (_: held) holes)) inner.one;
          optional = byUnit (holes: lib.mapAttrs (_: lift) (lib.filterAttrs (_: held) holes)) inner.optional;
          all = byUnit (lib.mapAttrs (_: ps: map lift (lib.filter held ps))) inner.all;
        };

      withInnerWiring =
        arity: top:
        lib.foldl' lib.mergeAttrs top (
          map (u: (innerWiringOf u).${arity}) (lib.filter isInclusion instNames)
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

        # An inclusion is a node and so are its units: the edge into one is a
        # real fact about the inclusion's own hole, and the edges between its
        # units are real facts about them. So the graph is hierarchical where
        # the link is, and flat everywhere else.
        # Every unit that emits, at any depth, which is what a parent recurses
        # through when this link is the body of one of its inclusions.
        leaves = leafNames;

        inherit floeNames;

        graph = {
          nodes = lib.unique nodeNames;
          edges = evalEdges ++ innerEdges ++ deployEdges;
        };

        # Keyed by what emits, which after an inclusion is its units rather than
        # it. Deploy edges are derived from tokens in output, and output comes
        # from leaves, so this needs no special case beyond the flattening.
        phases = lib.genAttrs leafNames (phaseOf [ ]);

        # Every group of units whose holes resolve to each other, at any depth.
        # A unit absent from all of them is its own cache unit. ADR 0008.
        inherit cycles;

        inherit deferredSites;

        # The distinct retrievals a backend must implement for this link. A
        # derived view of `deferredSites`, carried because a preflight wants one
        # lookup rather than a walk.
        deferredRetrievals = lib.unique (map (s: s.token.retrieval) deferredSites);

        # Keyed by the unit whose hole it is, at any depth, which is what the
        # qualification above makes possible.
        inherit exportOriginOf;

        # `withBacking` runs on this level's own wiring, before the inner
        # levels are merged in: an inner reference's `instName` is a path and
        # not a unit of this link, and it arrived backed already because the
        # inner result went through the same step. `lift` qualifies both.
        wiring = {
          one = withInnerWiring "one" (lib.mapAttrs (_: lib.mapAttrs (_: withBacking)) wiringOne);
          optional = withInnerWiring "optional" (
            lib.mapAttrs (_: lib.mapAttrs (_: withBacking)) wiringOptional
          );
          all = withInnerWiring "all" (lib.mapAttrs (_: lib.mapAttrs (_: map withBacking)) wiringAll);
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
          synthetic
          isSynthetic
          withinInclusion
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

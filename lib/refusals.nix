# Every way a link is refused, and the order they are reported in.
#
# Nine checks, all reading headers alone, all producing a list of messages, all
# consumed by one `firstRefusal`. They were half of `lib/link.nix`, which also
# resolves, evaluates a fixpoint, derives a graph and collects output — and
# they are the half a reader reaches for most often, because every error
# message in the system is here.
#
# The order is a decision, not an accident: a unit that answers its own hole
# is reported before the unnamed-optional-provider error, because a floe that
# both provides and optionally requires one signature trips both and the first
# is the better diagnosis. Likewise a name collision comes first, since
# resolution keys on names and a link whose names are ambiguous cannot be
# reasoned about at all.
{ lib, types }:

{
  # firstRefusal :: Context -> string | null
  #
  # Null when the link stands. The checks are a list rather than an `if`/`else
  # if` chain so the order is data, and `findFirst` keeps them lazy — nothing
  # computes compatibility for a link whose names already collide.
  firstRefusal =
    ctx:
    let
      inherit (ctx)
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
      refusals = [
        (lib.optional (nameCollisions != [ ]) (
          "floe link error: a hole or provide name means more than one signature.\n  - "
          + lib.concatStringsSep "\n  - " nameCollisions
          + "\n\nA reader seeing `requires.<name>` should be able to tell what it is "
          + "without looking it up. Rename one to its signature's `canonicalName`."
        ))
        (lib.optional (singletonBreaches != [ ]) (
          "floe link error: a singleton floe is instantiated more than once.\n  - "
          + lib.concatStringsSep "\n  - " singletonBreaches
          + "\n\nIts body writes fixed paths instead of keying them by "
          + "`config.floe.name`, so every instance emits the same output. Identical "
          + "values merge without complaint, which would leave you with one of it "
          + "and no error saying so.\n\nEither instantiate it once, or make the "
          + "floe key its output by `config.floe.name` and drop `singleton`."
        ))
        (lib.optional (surfaceCollisions != [ ]) (
          "floe link error: a hole name is declared on two singular surfaces.\n  - "
          + lib.concatStringsSep "\n  - " surfaceCollisions
          + "\n\nBoth resolve into `requires`, so one of them would be dropped with "
          + "nothing saying which. Pick the arity the floe means: `requires` if it "
          + "cannot work without the thing, `optional` if it can."
        ))
        (lib.optional (collectBindings != [ ]) (
          "floe link error: a binding names a collected hole.\n  - "
          + lib.concatStringsSep "\n  - " collectBindings
          + "\n\nA collection's arity is every provider in the link, so there is "
          + "nothing for a binding to choose, and this one was being ignored. Remove "
          + "it, or declare the hole `requires` or `optional` if exactly one provider "
          + "is what the floe meant."
        ))
        (lib.optional (selfResolutions != [ ]) (
          "floe link error: a unit does not satisfy its own hole.\n  - "
          + lib.concatStringsSep "\n  - " selfResolutions
          + "\n\nRead the provide directly; it is in scope and needs no link."
        ))
        (lib.optional (unnamedOptionals != [ ]) (
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
        ))
        (lib.optional (incompatibilities != [ ]) (
          "floe link error: a provider cannot answer the signature a unit asked for.\n  - "
          + lib.concatStringsSep "\n  - " incompatibilities
          + "\n\nResolution matches a signature by name, so two definitions of one name "
          + "link and then fail wherever the value is read, naming no floe. Widen the "
          + "provider's signature, or narrow the requirer's to the fields it uses."
        ))
      ];
    in
    lib.findFirst (m: m != null) null (map (o: if o == [ ] then null else lib.head o) refusals);
}

# Pins the linker against the worked example in `support`: hole resolution,
# the three arities, sealing, and the two edge kinds.
#
# `examples.nix` is the other half, against the two distributions in
# `../examples`. Both return `lib.runTests` failure lists, concatenated at the
# bottom of this file.
{ lib }:

let
  floe = import ../lib { inherit lib; };
  fixture = import ./support { inherit lib floe; };

  T = floe.T;
  SELF = floe.mkSig {
    name = "SELF";
    canonicalName = "self";
    description = "Fixture: a signature a floe provides and tries to require.";
    fields = {
      v = T.str;
    };
  };

  # A consumer echoes back what its hole resolved to, so a silent
  # non-resolution fails the test rather than passing it quietly.
  ECHO = floe.mkSig {
    name = "ECHO";
    canonicalName = "echo";
    description = "Fixture: echoes back what a hole resolved to.";
    fields = {
      v = T.str;
    };
  };

  # One floe, one signature, and a switch for whether it also asks for it.
  selfLink =
    { asksForIt }:
    let
      u = floe.mkFloe (
        {
          name = "narcissus";
          summary = "Fixture floe for a test suite.";
          provides.it = SELF;
          modules = [
            {
              config.floe.provides.it = {
                v = "mine";
              };
            }
          ];
        }
        // lib.optionalAttrs asksForIt { requires.it2 = SELF; }
      );
    in
    floe.link { units.narcissus = u.instantiate { }; };

  # A unit collecting a signature it also provides. Nothing else provides it,
  # so an empty result says both that self is excluded and that no providers
  # is legal rather than an error.
  narcissusCollecting =
    let
      u = floe.mkFloe {
        name = "narcissus";
        summary = "Fixture floe for a test suite.";
        provides.it = SELF;
        collects.mine = SELF;
        modules = [
          (
            { config, ... }:
            {
              config.floe.provides.it.v = toString (lib.length (lib.attrNames config.floe.collects.mine));
            }
          )
        ];
      };
    in
    floe.link { units.narcissus = u.instantiate { }; };

  # Two providers of one signature and a consumer that says which it means.
  # `bind` is the deployer's, because a floe cannot know its peers' names.
  twoIssuers =
    { binding }:
    let
      issuer =
        n:
        floe.mkFloe {
          name = "issuer-${n}";
          summary = "Fixture floe for a test suite.";
          provides.it = SELF;
          modules = [ { config.floe.provides.it.v = n; } ];
        };

      consumer = floe.mkFloe {
        name = "consumer";
        summary = "Fixture floe for a test suite.";
        requires.issuance = SELF;
        provides.echo = ECHO;
        modules = [
          (
            { config, ... }:
            {
              config.floe.provides.echo.v = config.floe.requires.issuance.v;
            }
          )
        ];
      };

      inst = consumer.instantiate { };
    in
    floe.link {
      units = {
        internal = (issuer "internal").instantiate { };
        public = (issuer "public").instantiate { };
        consumer = if binding == null then inst else inst.bind { issuance = binding; };
      };
    };

  fails = expr: !(builtins.tryEval (builtins.deepSeq expr "evaluated")).success;

  # Two variants with different field names, so a value carrying the wrong
  # one fails on the shape and not only on the tag.
  unionTy = T.taggedUnion {
    small = T.record { size = T.int; };
    large = T.record { label = T.str; };
  };

  nestedTy = T.record {
    name = T.str;
    config = unionTy;
  };

  # Where a deferred value will be readable, for the fixtures that mint one.
  REF = floe.mkSig {
    name = "fixture.ref";
    canonicalName = "ref";
    description = "Fixture: where a deferred value will be readable.";
    fields = {
      path = T.str;
    };
  };

  # One signature *name*, two shapes. This is what version skew between
  # repositories looks like: resolution matches on the name, so the link used to
  # succeed and the consumer then died on `attribute 'port' missing`, naming no
  # floe and catchable by nothing. ADR 0007.
  skewed =
    {
      provided,
      required,
      value,
      read ? (r: r.host),
    }:
    let
      sigWith =
        fields:
        floe.mkSig {
          name = "SKEW";
          canonicalName = "skew";
          description = "Fixture: one name, two shapes.";
          inherit fields;
        };

      prov = floe.mkFloe {
        name = "prov";
        summary = "Fixture floe for a test suite.";
        provides.skew = sigWith provided;
        body = args: { provides.skew = value args; };
      };

      cons = floe.mkFloe {
        name = "cons";
        summary = "Fixture floe for a test suite.";
        requires.skew = sigWith required;
        provides.echo = ECHO;
        body = { requires, ... }: { provides.echo.v = toString (read requires.skew); };
      };
    in
    floe.link {
      units = {
        prov = prov.instantiate { };
        cons = cons.instantiate { };
      };
    };

  # The same skew, read through a collection rather than an exactly-one hole: a
  # collection's members are read through the collector's signature too.
  skewedCollection =
    { provided, required }:
    let
      sigWith =
        fields:
        floe.mkSig {
          name = "SKEW";
          canonicalName = "skew";
          description = "Fixture: one name, two shapes.";
          inherit fields;
        };

      prov = floe.mkFloe {
        name = "prov";
        summary = "Fixture floe for a test suite.";
        provides.skew = sigWith provided;
        body = { ... }: {
          provides.skew = {
            host = "h";
          };
        };
      };

      cons = floe.mkFloe {
        name = "cons";
        summary = "Fixture floe for a test suite.";
        collects.skew = sigWith required;
        provides.echo = ECHO;
        body = { collects, ... }: {
          provides.echo.v = toString (lib.length (lib.attrNames collects.skew));
        };
      };
    in
    floe.link {
      units = {
        prov = prov.instantiate { };
        cons = cons.instantiate { };
      };
    };

  # A zero-or-one hole, with switches for the three things that decide it:
  # whether anything provides it, and whether the deployer named a provider
  # per-unit or link-wide.
  optionalLink =
    {
      withProvider,
      binding ? null,
      default ? null,
    }:
    let
      consumer = floe.mkFloe {
        name = "consumer";
        summary = "Fixture floe for a test suite.";
        optional.issuance = SELF;
        provides.echo = ECHO;
        body =
          {
            requires,
            ...
          }:
          {
            provides.echo.v = if requires.issuance == null then "none" else requires.issuance.v;
          };
      };

      issuer = floe.mkFloe {
        name = "issuer";
        summary = "Fixture floe for a test suite.";
        provides.it = SELF;
        body = { ... }: {
          provides.it = {
            v = "internal";
          };
        };
      };

      inst = consumer.instantiate { };
    in
    floe.link {
      units = {
        consumer = if binding == null then inst else inst.bind { issuance = binding; };
      }
      // lib.optionalAttrs withProvider { internal = issuer.instantiate { }; };
      defaults = lib.optionalAttrs (default != null) { SELF = default; };
    };

  # ---- Inclusion fixtures (ADR 0006) ---------------------------------------

  OPAQUE = floe.mkSig {
    name = "OPAQUE";
    canonicalName = "opaque";
    description = "Fixture: an output signature holding anything.";
    fields = T.attrsOf T.any;
  };

  # Two fields, one of which an export will drop — which is what replaces
  # `T.local`: the boundary declares what crosses.
  WIDE = floe.mkSig {
    name = "WIDE";
    canonicalName = "wide";
    description = "Fixture: a signature with an inside-only field.";
    fields = {
      v = T.str;
      insideOnly = T.str;
    };
  };

  NARROW = floe.mkSig {
    name = "NARROW";
    canonicalName = "narrow";
    description = "Fixture: the same thing, as a peer outside may read it.";
    fields = {
      v = T.str;
    };
  };

  # Provides WIDE, and mints a deferred value so a consumer *inside* the same
  # inclusion produces a token whose source is an inner unit.
  insider = floe.mkFloe {
    name = "insider";
    summary = "Fixture floe for a test suite.";
    provides.wide = WIDE;
    body =
      { floe, ... }:
      {
        provides.wide = {
          v = "inner";
          insideOnly = "means nothing out there";
        };
      };
  };

  # Reads the inclusion's open hole and writes a token into output, so both
  # halves of site qualification are exercised: a token minted inside and one
  # that arrived from the parent.
  emitter = floe.mkFloe {
    name = "emitter";
    summary = "Fixture floe for a test suite.";
    requires.wide = WIDE;
    requires.deferredThing = DEFERRED_THING;
    out.opaque = OPAQUE;
    body =
      { requires, floe, ... }:
      {
        out.opaque = {
          fromOutside = requires.deferredThing.token;
          fromInside = floe.mkDeferred REF { path = "/run/inner"; };
        };
      };
  };

  DEFERRED_THING = floe.mkSig {
    name = "DEFERRED_THING";
    canonicalName = "deferredThing";
    description = "Fixture: carries a value that does not exist yet.";
    fields = {
      token = T.deferred T.str;
    };
  };

  minter = floe.mkFloe {
    name = "minter";
    summary = "Fixture floe for a test suite.";
    provides.deferredThing = DEFERRED_THING;
    body =
      { floe, ... }:
      {
        provides.deferredThing.token = floe.mkDeferred REF { path = "/run/outer"; };
      };
  };

  # The inclusion: one open hole the parent fills, one export narrowed on the
  # way out, and two units inside.
  enclosure = floe.mkInclusion {
    name = "enclosure";
    summary = "Fixture inclusion for a test suite.";
    requires.deferredThing = DEFERRED_THING;
    provides.narrow = NARROW;
    exports.narrow = "insider";
    units = _: {
      insider = insider.instantiate { };
      emitter = emitter.instantiate { };
    };
  };

  nestedLink = floe.link {
    units = {
      minter = minter.instantiate { };
      env = enclosure.instantiate { };
    };
  };

  # An inclusion holding an inclusion. Two levels, because one level cannot
  # distinguish an inner link's *nodes* from its *leaves* — they coincide until
  # something inside is itself an inclusion, and the flattening depends on the
  # difference.
  twoDeep =
    let
      inner = floe.mkInclusion {
        name = "inner";
        summary = "Fixture inclusion for a test suite.";
        requires.deferredThing = DEFERRED_THING;
        provides.narrow = NARROW;
        exports.narrow = "insider";
        units = _: {
          insider = insider.instantiate { };
          emitter = emitter.instantiate { };
        };
      };

      outer = floe.mkInclusion {
        name = "outer";
        summary = "Fixture inclusion for a test suite.";
        requires.deferredThing = DEFERRED_THING;
        provides.narrow = NARROW;
        exports.narrow = "nested";
        units = _: { nested = inner.instantiate { }; };
      };
    in
    floe.link {
      units = {
        minter = minter.instantiate { };
        env = outer.instantiate { };
      };
    };

  # A derivation, as far as any Nix consumer is concerned. `out` is itself,
  # which is what made walking one a stack overflow.
  fakeDrv = rec {
    type = "derivation";
    name = "hello";
    outPath = "/nix/store/0000000000000000000000000000000-hello";
    drvPath = "/nix/store/1111111111111111111111111111111-hello.drv";
    out = fakeDrv;
    all = [ fakeDrv ];
  };

  deployment = fixture.deployment;

  # Edges are compared as sorted strings: the linker's list order follows
  # attribute order, which is an implementation detail the test should not pin.
  edge = e: "${e.kind}:${e.from}->${e.to} via ${e.via}";
  edges = lib.sort (a: b: a < b) (map edge deployment.graph.edges);
in
(import ./examples.nix { inherit lib floe; })
++ lib.runTests {

  # The two halves of the type boundary, each of which fails deep inside
  # nixpkgs when the wrong kind of type reaches it.
  testAFloeTypeInAnInputIsRefused = {
    expr = fails (
      floe.mkFloe {
        name = "wrong-way-round";
        summary = "Fixture: declares an input with a floe data schema.";
        inputs.replicas = lib.mkOption {
          type = T.int;
          default = 2;
        };
      }
    );
    expected = true;
  };

  testANixosTypeWhereAFloeTypeBelongsIsRefused = {
    expr = fails (T.checkValue [ "fixture" ] lib.types.str "x");
    expected = true;
  };

  # `T.moduleType` is the sanctioned crossing: its inner *is* a NixOS type.
  testModuleTypeStillTakesANixosType = {
    expr = T.checkValue [ "fixture" ] (T.moduleType lib.types.str) "x";
    expected = "x";
  };

  testNodesAreTheUnitNames = {
    expr = deployment.graph.nodes;
    expected = [
      "billing"
      "grafana"
      "ingress"
      "myapp"
    ];
  };

  # An eval edge says A needed B's config to render, one per contributor for a
  # collection. Two pairs are cycles laziness carries; the deploy edge is
  # derived from a deferred token the link-time scan found in `out.k8s`, and is
  # labelled with the *retrieval* — which says what a backend must implement to
  # satisfy it.
  testEdges = {
    expr = edges;
    expected = [
      "deploy:grafana->ingress via k8s.statusField"
      "eval:billing->grafana via observer"
      "eval:grafana->billing via dashboards"
      "eval:grafana->ingress via ingress"
      "eval:grafana->myapp via dashboards"
      "eval:myapp->grafana via observer"
    ];
  };

  # Phases fall out of the deploy subgraph alone. myapp is phase 0 despite
  # depending on grafana at eval time, because nothing it emits waits on
  # anything grafana applies.
  testPhases = {
    expr = deployment.phases;
    expected = {
      billing = 0;
      grafana = 1;
      ingress = 0;
      myapp = 0;
    };
  };

  # Sealing restricts to the signature. grafana's body defines exactly these
  # two, but a body defining more would still surface only these.
  testProvidesAreSealedToTheSignature = {
    expr = lib.attrNames deployment.provides.grafana.observer;
    expected = [
      "dashboards"
      "ingressUrl"
    ];
  };

  testProvidedValuesSurvive = {
    expr = deployment.provides.grafana.observer.ingressUrl;
    expected = "https://grafana.lab.example.com";
  };

  # A collection arrives keyed by the providing unit, so a consumer folding
  # over it can name one and two providers cannot collide. Both instances of
  # one floe are here, which is the arity `requires` cannot express.
  testACollectionHoldsEveryProvider = {
    expr = deployment.provides.grafana.observer.dashboards;
    expected = {
      billing.url = "https://grafana.lab.example.com/d/app-billing";
      myapp.url = "https://grafana.lab.example.com/d/app-myapp";
    };
  };

  # Two providers is an error for an unbound hole — the coherence rule the
  # whole model rests on.
  testTwoProvidersWithoutABindingIsRefused = {
    expr = fails (twoIssuers { binding = null; }).provides;
    expected = true;
  };

  # And resolvable with one. This is what makes a second provider addable at
  # all: `requires` stays exactly-one, per consumer, by naming which.
  testABindingPicksTheProvider = {
    expr = (twoIssuers { binding = "public"; }).provides.consumer.echo.v;
    expected = "public";
  };

  # `<unit>/<provide>` too, spelled as `lab.clusters.<c>.offers` spells it.
  testABindingMayNameTheProvideAsWell = {
    expr = (twoIssuers { binding = "internal/it"; }).provides.consumer.echo.v;
    expected = "internal";
  };

  testABindingToANonProviderIsRefused = {
    expr = fails (twoIssuers { binding = "nobody"; }).provides;
    expected = true;
  };

  # An eval cycle is legal and laziness carries it; a deploy cycle is not,
  # because a phase is a number and each side would have to be after the
  # other. `phaseOf` refuses it with the path, which nothing had pinned.
  testADeferredValueCycleIsRefused = {
    expr = fails fixture.failures.deferredCycle;
    expected = true;
  };

  # Where an exactly-one hole is an error, a collection is simply empty: the
  # collector is excluded, and nothing else here provides SELF. An empty
  # collection is legal, which is what separates it from the other arities.
  testACollectionExcludesTheCollectorAndMayBeEmpty = {
    expr = narcissusCollecting.provides.narcissus.it.v;
    expected = "0";
  };

  # `providersOf` scans every unit including the requester, so a unit must
  # not resolve its own hole to itself: an otel-collector providing
  # TRACE_INGEST would export into its own receiver.
  testAFloeDoesNotSatisfyItsOwnHole = {
    expr = fails (selfLink { asksForIt = true; }).provides;
    expected = true;
  };

  # The paired positive. Without it the refusal above could pass because the
  # fixture fails to link for some unrelated reason, which is how five
  # refusals in nix/checks/secret-sharing.nix once passed for the wrong one.
  testTheSameFloeLinksFineWhenItOnlyProvides = {
    expr = (selfLink { asksForIt = false; }).provides.narcissus.it;
    expected = {
      v = "mine";
    };
  };

  testOutputsAreCollectedByKind = {
    expr = lib.attrNames deployment.out;
    expected = [
      "catallaxy.meta"
      "k8s.manifests"
    ];
  };
  # What an unfilled hole is able to suggest. A throw's text is unreachable
  # from `tryEval`, so the listing is tested here and the sentence around it
  # is not tested at all.
  testCandidatesNameEveryFloeProvidingIt = {
    expr = floe.candidatesFor {
      cert-manager = [ "X509_ISSUANCE" ];
      external-secrets = [ "SECRET_STORE" ];
      gateway = [ "API_GATEWAY" ];
      openbao = [ "SECRET_STORE" ];
    } "SECRET_STORE";
    expected = [
      "external-secrets"
      "openbao"
    ];
  };

  # An empty catalogue is the degradation, not an error: core ships no floe
  # set, so a caller that passes none still links and still refuses, it just
  # has nothing to suggest.
  testNoCatalogueSuggestsNothing = {
    expr = floe.candidatesFor { } "SECRET_STORE";
    expected = [ ];
  };

  # Collection is keyed by unit and disjoint by construction: no merge.
  testOutputsAreKeyedByUnit = {
    expr = lib.attrNames deployment.out."k8s.manifests";
    expected = [
      "billing"
      "grafana"
      "ingress"
      "myapp"
    ];
  };

  # ---- tagged unions -------------------------------------------------------
  #
  # The shape a kind reaches for when a value is one of several things.

  testTheNamedVariantIsChecked = {
    expr = floe.T.checkValue [ ] unionTy { small.size = 1; };
    expected = {
      small.size = 1;
    };
  };

  testTheOtherVariantIsAlsoChecked = {
    expr = floe.T.checkValue [ ] unionTy { large.label = "wide"; };
    expected = {
      large.label = "wide";
    };
  };

  # The variant's own schema still applies. A union that accepted anything
  # under a known name would check only the spelling of the tag.
  testAVariantWithTheWrongFieldTypeIsRefused = {
    expr = fails (floe.T.checkValue [ ] unionTy { small.size = "1"; });
    expected = true;
  };

  testAVariantMissingAFieldIsRefused = {
    expr = fails (floe.T.checkValue [ ] unionTy { small = { }; });
    expected = true;
  };

  # The three ways the tag itself can be wrong. Zero and two are what `record`
  # cannot say at all: it would accept both and call them well-typed.
  testNoVariantIsRefused = {
    expr = fails (floe.T.checkValue [ ] unionTy { });
    expected = true;
  };

  testTwoVariantsAtOnceAreRefused = {
    expr = fails (
      floe.T.checkValue [ ] unionTy {
        small.size = 1;
        large.label = "wide";
      }
    );
    expected = true;
  };

  testAnUnknownVariantIsRefused = {
    expr = fails (floe.T.checkValue [ ] unionTy { medium.size = 2; });
    expected = true;
  };

  # Sealing, as `record` does it: a union restricts to the variant it named,
  # so a stray sibling cannot ride along inside the value.
  testAnUnknownVariantIsRefusedEvenBesideAKnownOne = {
    expr = fails (
      floe.T.checkValue [ ] unionTy {
        small.size = 1;
        medium.size = 2;
      }
    );
    expected = true;
  };

  # A union nests like any other type: this is what lets a kind carry one
  # field that is a union and the rest ordinary.
  testAUnionNestsInsideARecord = {
    expr = floe.T.checkValue [ ] nestedTy {
      name = "app";
      config.small.size = 3;
    };
    expected = {
      name = "app";
      config.small.size = 3;
    };
  };

  testAUnionInsideARecordStillRefusesTwoVariants = {
    expr = fails (
      floe.T.checkValue [ ] nestedTy {
        name = "app";
        config = {
          small.size = 3;
          large.label = "wide";
        };
      }
    );
    expected = true;
  };

  # RFC 0001 §4.3: a floe's complete interface is available from its
  # declaration header without evaluating the body.

  # Required, not optional. An optional documentation field is one half the
  # set omits, and a derived interface document with holes in it is one nobody
  # trusts enough to read.
  testASignatureMustSayWhatItIsFor = {
    expr = fails (
      floe.mkSig {
        name = "X";
        canonicalName = "x";
        fields = { };
      }
    );
    expected = true;
  };

  # `fields` takes the attrset a signature is named for, and wraps it in
  # `T.record` so that sealing drops what the signature did not declare.
  testFieldsAsAnAttrsetSealsLikeARecord = {
    expr =
      let
        sig = floe.mkSig {
          name = "F";
          canonicalName = "f";
          description = "Fixture: fields as an attrset.";
          fields = {
            v = T.str;
          };
        };
      in
      T.checkValue [ ] sig.shape {
        v = "kept";
        extra = "dropped";
      };
    expected = {
      v = "kept";
    };
  };

  # And a bare `T` goes in the same place, for a signature with nothing worth
  # naming — a rendered manifest. Both branches are exercised by the examples
  # too, and this is the one that says which is which.
  testFieldsAlsoTakesABareType = {
    expr =
      let
        sig = floe.mkSig {
          name = "F";
          canonicalName = "f";
          description = "Fixture: fields as a bare type.";
          fields = T.attrsOf T.any;
        };
      in
      {
        tag = sig.shape.tag;
        keepsEverything = T.checkValue [ ] sig.shape {
          a = 1;
          b = 2;
        };
      };
    expected = {
      tag = "attrsOf";
      keepsEverything = {
        a = 1;
        b = 2;
      };
    };
  };

  testASignatureMustSayWhatItIsCalled = {
    expr = fails (
      floe.mkSig {
        name = "X";
        description = "d";
        fields = { };
      }
    );
    expected = true;
  };

  # ---- what `checkInputs` borrows from the module system --------------------
  #
  # `lib.modules.mergeDefinitions` is nixpkgs' per-option machinery, and it is
  # exported under a blanket note that not everything in that list is a public
  # interface. These three pin the behaviours `checkInputs` relies on, so a
  # nixpkgs bump that moves them fails here rather than in someone's deploy.
  #
  # Written against `mkFloe` rather than against `mergeDefinitions` directly:
  # what matters is that a floe's inputs still behave, not how.

  # The one that cannot be hand-rolled. A submodule's defaults live inside its
  # own option declarations, and only the module system reaches them.
  testASubmoduleInputGetsItsNestedDefaults = {
    expr =
      (
        (floe.mkFloe {
          name = "sub-inputs";
          summary = "Fixture: an input whose type is a submodule.";
          inputs.tls = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                cert = lib.mkOption {
                  type = lib.types.str;
                  default = "/etc/cert.pem";
                };
              };
            };
            default = { };
          };
          body = { ... }: { };
        }).instantiate
          { tls.enable = true; }
      ).inputsChecked.tls;
    expected = {
      enable = true;
      cert = "/etc/cert.pem";
    };
  };

  # Property wrappers in an instantiate call. Nothing in this repo writes one,
  # but the module system handles them and so does floe, for free.
  testPropertyWrappersInASuppliedInputAreHandled = {
    expr =
      let
        f = floe.mkFloe {
          name = "wrapped";
          summary = "Fixture: a plain scalar input.";
          inputs.port = lib.mkOption {
            type = lib.types.port;
            default = 5432;
          };
          body = { ... }: { };
        };
      in
      {
        mkIf = (f.instantiate { port = lib.mkIf true 5433; }).inputsChecked.port;
        mkForce = (f.instantiate { port = lib.mkForce 5434; }).inputsChecked.port;
      };
    expected = {
      mkIf = 5433;
      mkForce = 5434;
    };
  };

  # And it still refuses. Lazily, per input, the way NixOS does — which is why
  # this forces the value rather than just instantiating.
  testABadlyTypedInputIsRefusedWhenRead = {
    expr =
      let
        inst =
          (floe.mkFloe {
            name = "badly-typed";
            summary = "Fixture: a port input given a non-port.";
            inputs.port = lib.mkOption {
              type = lib.types.port;
              default = 5432;
            };
            body = { ... }: { };
          }).instantiate
            { port = 99999; };
      in
      fails inst.inputsChecked.port;
    expected = true;
  };

  # The shape of the call is checked eagerly, because a typo or a forgotten
  # required input is wrong whether or not anything reads it.
  testTheShapeOfAnInstantiateCallIsCheckedEagerly = {
    expr =
      let
        f = floe.mkFloe {
          name = "shapely";
          summary = "Fixture: one defaulted input and one required.";
          inputs = {
            port = lib.mkOption {
              type = lib.types.port;
              default = 5432;
            };
            required = lib.mkOption { type = lib.types.str; };
          };
          body = { ... }: { };
        };
      in
      {
        undeclaredKey =
          fails
            (f.instantiate {
              required = "x";
              bogus = 1;
            }).inputsChecked;
        missingRequired = fails (f.instantiate { }).inputsChecked;
        bothGiven = (f.instantiate { required = "x"; }).inputsChecked.required;
      };
    expected = {
      undeclaredKey = true;
      missingRequired = true;
      bothGiven = "x";
    };
  };

  # Nix cannot read comments, so without this a floe's header prose reaches no
  # tool and the only machine-readable thing about it is its name.
  testAFloeMustSayWhatItInstalls = {
    expr = fails (floe.mkFloe { name = "x"; });
    expected = true;
  };

  # The link result carries each unit's input declarations — type, default
  # and description. The declaration, not the supplied value.
  testTheLinkResultCarriesInputDocs = {
    expr = deployment.inputs.grafana.size or null;
    expected = {
      type = "string";
      default = "\"10Gi\"";
      description = "PVC size for Grafana storage.";
    };
  };

  # A required input has no default, and the doc says so rather than
  # inventing one — which is the difference a deployer needs to see.
  testARequiredInputHasNoDefault = {
    expr = deployment.inputs.grafana.adminUser.default or "MISSING";
    expected = null;
  };

  # ---- Compatibility (ADR 0007) --------------------------------------------
  #
  # The failure these exist for: two definitions of one signature name linked
  # cleanly, and the consumer died several frames later on Nix's
  # `attribute 'port' missing` — no floe named, no field, not catchable.

  testAProviderMissingAFieldTheRequirerDeclaresIsRefused = {
    expr = fails (skewed {
      provided = T.record { host = T.str; };
      required = T.record {
        host = T.str;
        port = T.port;
      };
      value = { ... }: { host = "h"; };
    });
    expected = true;
  };

  # The paired positive, and the direction that has to stay legal: extra fields
  # on the provider are what sealing drops, so widening a signature is a
  # compatible change and needs no version number.
  testAProviderWithExtraFieldsAnswersFine = {
    expr =
      (skewed {
        provided = T.record {
          host = T.str;
          port = T.port;
        };
        required = T.record { host = T.str; };
        value = { ... }: {
          host = "h";
          port = 5432;
        };
      }).provides.cons.echo.v;
    expected = "h";
  };

  # A refinement answers what it refines: every DNS name is a string. Without
  # this a provider promising *more* than was asked for would be refused.
  testARefinementAnswersWhatItRefines = {
    expr =
      (skewed {
        provided = T.record { host = T.dnsName; };
        required = T.record { host = T.str; };
        value = { ... }: { host = "db.example.com"; };
      }).provides.cons.echo.v;
    expected = "db.example.com";
  };

  # The one asymmetry. A value that does not exist until after apply cannot
  # answer a field something reads at eval, and saying so from the headers names
  # both sides — where the same mistake found at read time named neither.
  testADeferredProviderCannotAnswerAConcreteRequirer = {
    expr = fails (skewed {
      provided = T.record { host = T.deferred T.str; };
      required = T.record { host = T.str; };
      value = { floe, ... }: { host = floe.mkDeferred REF { path = "/run/x"; }; };
    });
    expected = true;
  };

  # And the other way round is fine, because such a requirer handles both.
  testAConcreteProviderAnswersADeferredRequirer = {
    expr =
      (skewed {
        provided = T.record { host = T.str; };
        required = T.record { host = T.deferred T.str; };
        value = { ... }: { host = "h"; };
      }).provides.cons.echo.v;
    expected = "h";
  };

  # Variance for a closed set runs the other way: the provider must promise no
  # more variety than the requirer admits.
  testAWiderEnumCannotAnswerANarrowerOne = {
    expr = fails (skewed {
      provided = T.record {
        host = T.enum [
          "a"
          "b"
        ];
      };
      required = T.record { host = T.enum [ "a" ]; };
      value = { ... }: { host = "a"; };
    });
    expected = true;
  };

  # A collection's members are read through the collector's signature, so they
  # are checked the same way. Nothing else in the suite would have caught this.
  testACollectionsMembersAreCheckedToo = {
    expr = fails (skewedCollection {
      provided = T.record { host = T.str; };
      required = T.record {
        host = T.str;
        port = T.port;
      };
    });
    expected = true;
  };

  # ---- The third arity -----------------------------------------------------

  testAnOptionalHoleWithNoProviderIsNull = {
    expr = (optionalLink { withProvider = false; }).provides.consumer.echo.v;
    expected = "none";
  };

  # The asymmetry with `requires`, and the reason it is here: a provider merely
  # being present wires nothing, so adding a floe to a link can never silently
  # change another floe's output. Erroring rather than no-opping, because a
  # deployer who added the provider and got nothing needs to be told why.
  testAnOptionalHoleWithAnUnnamedProviderIsRefused = {
    expr = fails (optionalLink {
      withProvider = true;
    });
    expected = true;
  };

  testABindingWiresAnOptionalHole = {
    expr =
      (optionalLink {
        withProvider = true;
        binding = "internal";
      }).provides.consumer.echo.v;
    expected = "internal";
  };

  # The link-wide spelling, so a lab pays one line rather than one per consumer.
  testADefaultWiresAnOptionalHole = {
    expr =
      (optionalLink {
        withProvider = true;
        default = "internal";
      }).provides.consumer.echo.v;
    expected = "internal";
  };

  # An unwired hole read nothing, so it is not an edge — which is what keeps it
  # out of the deploy ordering as well.
  testAnUnwiredOptionalHoleIsNotAnEdge = {
    expr = (optionalLink { withProvider = false; }).graph.edges;
    expected = [ ];
  };

  testAWiredOptionalHoleIsAnEvalEdge = {
    expr =
      map edge
        (optionalLink {
          withProvider = true;
          binding = "internal";
        }).graph.edges;
    expected = [ "eval:consumer->internal via issuance" ];
  };

  # Same argument as for `requires`: an otel-collector that provided
  # TRACE_INGEST would resolve its own trace backend to itself.
  testAFloeDoesNotSatisfyItsOwnOptionalHole = {
    expr = fails (
      floe.link {
        units.narcissus =
          (floe.mkFloe {
            name = "narcissus";
            summary = "Fixture floe for a test suite.";
            provides.it = SELF;
            optional.it2 = SELF;
            body = { ... }: {
              provides.it = {
                v = "mine";
              };
            };
          }).instantiate
            { };
      }
    );
    expected = true;
  };

  # Both singular arities resolve into one `requires` attrset, so a name on both
  # would drop one of them with nothing saying which.
  testAHoleDeclaredOnBothSingularSurfacesIsRefused = {
    expr = fails (
      floe.link {
        units.greedy =
          (floe.mkFloe {
            name = "greedy";
            summary = "Fixture: one hole name on two surfaces.";
            requires.issuance = SELF;
            optional.issuance = SELF;
            body = { ... }: { };
          }).instantiate
            { };
      }
    );
    expected = true;
  };

  # A binding on a collected hole was silently ignored — `wiringAll` takes every
  # provider and never consulted one — so a deployer who wrote it believed it
  # did something. A collection has nothing to choose.
  testABindingOnACollectedHoleIsRefused = {
    expr = fails (
      floe.link {
        units.collector =
          (
            (floe.mkFloe {
              name = "collector";
              summary = "Fixture: collects and is bound anyway.";
              collects.mine = SELF;
              body = { ... }: { };
            }).instantiate
              { }
          ).bind
            { mine = "whoever"; };
      }
    );
    expected = true;
  };

  # ---- Inclusion (ADR 0006) ------------------------------------------------

  # The half that makes inclusion worth having rather than a convenience:
  # nothing inside answers `deferredThing`, and the parent does. A cluster with
  # an open hole is reusable across labs.
  testAnOpenHoleIsFilledByTheParent = {
    expr = lib.attrNames nestedLink.out.OPAQUE;
    expected = [ "env/emitter" ];
  };

  # The export is a sealing step, which is the whole of what replaces `T.local`:
  # `insideOnly` is in the signature the units share and not in the one the
  # boundary declares, so a peer outside cannot read it.
  testAnExportIsSealedToItsOwnSignature = {
    expr = nestedLink.provides.env.narrow;
    expected = {
      v = "inner";
    };
  };

  # Output propagates with inner names qualified, because a backend wants one
  # bucket rather than a tree to walk.
  testInnerOutputIsQualifiedByTheInclusion = {
    expr = lib.attrNames (lib.groupBy (s: s.unit) nestedLink.deferredSites);
    expected = [ "env/emitter" ];
  };

  # Both halves of source qualification. `mkDeferred` binds `source` at
  # body-eval time, when the inner link cannot know it will be included — so a
  # token minted inside needs qualifying on the way out, and one that arrived
  # from the parent already names a unit the parent knows. Qualifying that
  # second one would invent a node that does not exist.
  testATokenMintedInsideIsQualifiedAndOneFromOutsideIsNot = {
    expr =
      let
        site = lib.head nestedLink.deferredSites;
        at = k: (lib.head (lib.filter (s: s.at == [ k ]) nestedLink.deferredSites)).token.source;
      in
      {
        inside = at "fromInside";
        outside = at "fromOutside";
      };
    expected = {
      inside = "env/emitter";
      outside = "minter";
    };
  };

  # Phases are keyed by what emits, which after an inclusion is its units
  # rather than it: an inclusion is not a thing that applies.
  testPhasesAreKeyedByTheUnitsInsideNotTheInclusion = {
    expr = nestedLink.phases;
    expected = {
      minter = 0;
      "env/emitter" = 1;
      "env/insider" = 0;
    };
  };

  # An inclusion resolves as a floe, so its own hole is an ordinary edge and
  # its units' edges are ordinary edges one level down.
  testAnInclusionIsANodeAndSoAreItsUnits = {
    expr = lib.sort (a: b: a < b) nestedLink.graph.nodes;
    expected = [
      "env"
      "env/emitter"
      "env/insider"
      "minter"
    ];
  };

  # Composition is closed: an inclusion is a floe, so an inclusion holds one the
  # same way it holds anything. The hole threads down two levels, the export
  # narrows at each boundary it crosses, and the output name says where it sat.
  testAnInclusionHoldsAnInclusion = {
    expr = {
      out = lib.attrNames twoDeep.out.OPAQUE;
      provides = twoDeep.provides.env.narrow;
    };
    expected = {
      out = [ "env/nested/emitter" ];
      provides = {
        v = "inner";
      };
    };
  };

  # The distinction one level cannot test. An inner link's nodes include its own
  # inclusions; its leaves do not. `phases` is keyed by leaves, because an
  # inclusion is not a thing that applies — so the intermediate `env/nested`
  # must be a node and must not have a phase.
  testAnIntermediateInclusionIsANodeWithNoPhase = {
    expr = {
      nodes = lib.sort (a: b: a < b) twoDeep.graph.nodes;
      phased = lib.sort (a: b: a < b) (lib.attrNames twoDeep.phases);
    };
    expected = {
      nodes = [
        "env"
        "env/nested"
        "env/nested/emitter"
        "env/nested/insider"
        "minter"
      ];
      phased = [
        "env/nested/emitter"
        "env/nested/insider"
        "minter"
      ];
    };
  };

  # The cost of declaring an inclusion's holes rather than inferring them, which
  # Backpack does and this cannot: `units` is a function of `inputs`, so what is
  # inside is not known until something evaluates, and a floe's interface has to
  # be readable from its header first. The under-declared direction is the
  # unfilled-hole error; this is the other one, and without it a deployer is
  # asked to wire a value that changes nothing.
  testAnInclusionHoleNothingInsideReadsIsRefused = {
    expr = fails (
      floe.link {
        units = {
          minter = minter.instantiate { };
          env =
            (floe.mkInclusion {
              name = "roomy";
              summary = "Fixture: declares a hole nothing inside reads.";
              requires.deferredThing = DEFERRED_THING;
              units = _: { insider = insider.instantiate { }; };
            }).instantiate
              { };
        };
      }
    );
    expected = true;
  };

  # An export signature exists to promise *less* than the one inside. One
  # promising more is a field a peer can ask for and nothing can answer, which
  # used to surface at that read rather than here.
  testAnExportThatWidensIsRefused = {
    expr = fails (
      floe.link {
        units = {
          minter = minter.instantiate { };
          env =
            (floe.mkInclusion {
              name = "widening";
              summary = "Fixture: exports a wider signature than it re-exports.";
              requires.deferredThing = DEFERRED_THING;
              # `insider` provides WIDE; NARROW is the narrowing of it, so
              # exporting *WIDE* from a unit providing NARROW is the mistake.
              provides.wide = WIDE;
              exports.wide = "narrower";
              units = _: {
                emitter = emitter.instantiate { };
                narrower =
                  (floe.mkFloe {
                    name = "narrower";
                    summary = "Fixture: provides only the narrow signature.";
                    provides.narrow = NARROW;
                    body = _: {
                      provides.narrow = {
                        v = "x";
                      };
                    };
                  }).instantiate
                    { };
              };
            }).instantiate
              { };
        };
      }
    );
    expected = true;
  };

  testExportingFromAUnitThatIsNotThereIsRefused = {
    expr = fails (
      floe.link {
        units.env =
          (floe.mkInclusion {
            name = "typo";
            summary = "Fixture: exports from a unit it does not hold.";
            provides.narrow = NARROW;
            exports.narrow = "insidr";
            units = _: { insider = insider.instantiate { }; };
          }).instantiate
            { };
      }
    );
    expected = true;
  };

  # An inclusion re-exports a provide; it does not compute one. So the two
  # declarations have to agree, and saying only one of them is the mistake.
  testAProvideWithNoExportIsRefused = {
    expr = fails (
      floe.mkInclusion {
        name = "half";
        summary = "Fixture: provides without saying where from.";
        provides.narrow = NARROW;
        units = _: { };
      }
    );
    expected = true;
  };

  testAnExportWithNoProvideIsRefused = {
    expr = fails (
      floe.mkInclusion {
        name = "half";
        summary = "Fixture: exports without declaring the signature.";
        exports.narrow = "insider";
        units = _: { };
      }
    );
    expected = true;
  };

  testAnInclusionWithABodyIsRefused = {
    expr = fails (
      floe.mkFloe {
        name = "confused";
        summary = "Fixture: an inclusion with a second body.";
        inclusion = {
          units = _: { };
          exports = { };
          defaults = { };
          policies = [ ];
        };
        body = _: { };
      }
    );
    expected = true;
  };

  # ---- Stub values ---------------------------------------------------------

  # The property worth having, and the only one: whatever `stubFor` derives
  # must satisfy the signature it was derived from. Checked against a signature
  # holding one of everything, because a stub that does not seal is worse than
  # no stub — a suite would fail on the harness rather than on the floe.
  testAStubSatisfiesTheSignatureItCameFrom = {
    expr =
      let
        everything = T.record {
          s = T.str;
          i = T.int;
          b = T.bool;
          p = T.port;
          u = T.url;
          d = T.dnsName;
          pkg = T.package;
          a = T.any;
          e = T.enum [
            "one"
            "two"
          ];
          n = T.nullOr T.str;
          l = T.listOf T.str;
          m = T.attrsOf T.int;
          deep = T.record { inner = T.port; };
          union = T.taggedUnion {
            small = T.record { size = T.int; };
            large = T.record { label = T.str; };
          };
          later = T.deferred T.str;
          folded = T.derivedFrom SELF T.str;
        };
        stub = T.stubFor everything;
      in
      T.checkValue [ "stub" ] everything stub == stub;
    expected = true;
  };

  # A refinement is not satisfied by any old value of what it refines, so these
  # are the ones a mechanical stub gets wrong if it is careless: port 0 is not a
  # port, and the empty string is not a DNS name.
  testStubsSatisfyTheRefinedScalars = {
    expr = {
      port = T.checkValue [ ] T.port (T.stubFor T.port);
      url = T.checkValue [ ] T.url (T.stubFor T.url);
      dnsName = T.checkValue [ ] T.dnsName (T.stubFor T.dnsName);
    };
    expected = {
      port = 1;
      url = "https://stub.invalid";
      dnsName = "stub.invalid";
    };
  };

  # A suite that cares what a field says overrides it; what the stub removes is
  # having to write the others.
  testAStubIsOverridable = {
    expr =
      let
        sig = floe.mkSig {
          name = "OVERRIDE";
          canonicalName = "override";
          description = "Fixture: a stub with one field that matters.";
          fields = {
            baseDomain = T.dnsName;
            scheme = T.enum [
              "http"
              "https"
            ];
          };
        };
      in
      T.checkValue [ ] sig.shape (T.stubFor sig.shape // { baseDomain = "lab.test"; });
    expected = {
      baseDomain = "lab.test";
      scheme = "http";
    };
  };

  # A module type's inhabitants are the module system's to know, so this is the
  # one case that cannot be derived — and saying so names the field instead of
  # producing something that fails to seal two frames later.
  testAStubForAModuleTypeIsRefused = {
    expr = fails (T.stubFor (T.moduleType lib.types.str));
    expected = true;
  };

  # ---- Internals are not reachable ----------------------------------------
  #
  # Both constructors carry an argument the library passes to itself. They were
  # public and documented as internal, which is a promise rather than a
  # property — and `mkFloe`'s own "the pattern is closed, an unknown key is an
  # error" was untrue of the one key where it mattered.

  # A forged `inclusion` would be routed as one with none of `mkInclusion`'s
  # checks run — no `exports`, so nothing saying where its provides come from.
  testAForgedInclusionIsRefused = {
    expr = fails (
      floe.mkFloe {
        name = "forged";
        summary = "Fixture: claims to be an inclusion.";
        provides.narrow = NARROW;
        inclusion = {
          units = _: { };
          exports = { };
          defaults = { };
          policies = [ ];
        };
      }
    );
    expected = true;
  };

  # And a forged `synthetic` would make a real unit vanish from `out`, `phases`
  # and the graph, silently, because every view is computed as if a synthetic
  # unit's value had simply arrived.
  testForgedLinkInternalsAreRefused = {
    expr = {
      synthetic = fails (
        floe.link {
          units.minter = minter.instantiate { };
          synthetic.minter = {
            hole = "x";
            signature = "X";
          };
        }
      );
      withinInclusion = fails (
        floe.link {
          units.minter = minter.instantiate { };
          withinInclusion = "pretend";
        }
      );
    };
    expected = {
      synthetic = true;
      withinInclusion = true;
    };
  };

  # ---- Narrowing -----------------------------------------------------------
  #
  # The relation an inclusion's `exports` rests on, and that a distribution
  # carrying a "what crosses a boundary" table rests on one layer up. Neither
  # was checking it.

  testANarrowerSignatureNarrows = {
    expr = floe.narrows WIDE NARROW;
    expected = [ ];
  };

  # The direction that matters: a "narrowing" that adds a field is the bug this
  # names, because it promises something the real one never had.
  testAWideningIsNotANarrowing = {
    expr = lib.length (floe.narrows NARROW WIDE);
    expected = 1;
  };

  # ---- Packages (ADR 0008) -------------------------------------------------

  testAPackageAcceptsADerivation = {
    expr = (T.checkValue [ "fixture" ] T.package fakeDrv).outPath;
    expected = "/nix/store/0000000000000000000000000000000-hello";
  };

  # The store path a derivation coerces to is the same thing by the time it
  # reaches output, so both are the type.
  testAPackageAcceptsAStorePath = {
    expr = T.checkValue [ "fixture" ] T.package "/nix/store/x-hello";
    expected = "/nix/store/x-hello";
  };

  testAPackageRefusesSomethingElse = {
    expr = fails (T.checkValue [ "fixture" ] T.package 42);
    expected = true;
  };

  # The crash this closes: a derivation is an attrset whose `out` is itself, so
  # the token scan walked it until the stack ran out — and a stack overflow is
  # not catchable, so `tryEval` could not even contain it. Every NixOS module
  # that writes `environment.systemPackages` puts one here.
  testADerivationInOutputDoesNotBreakTheTokenScan = {
    expr =
      let
        OUT = floe.mkSig {
          name = "fixture.out";
          canonicalName = "fixtureOut";
          description = "Fixture: output holding a package.";
          fields = {
            pkg = T.package;
          };
        };
        f = floe.mkFloe {
          name = "with-package";
          summary = "Fixture: emits a derivation.";
          out.fixtureOut = OUT;
          body = { ... }: {
            out.fixtureOut = {
              pkg = fakeDrv;
            };
          };
        };
      in
      (floe.link { units.a = f.instantiate { }; }).deferredSites;
    expected = [ ];
  };
}

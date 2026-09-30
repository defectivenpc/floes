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
    as = "self";
    description = "Fixture: a signature a floe provides and tries to require.";
    fields.v = T.str;
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

  # ---- externals: a hole answered from outside this link -------------------
  #
  # It echoes what it resolved, because declaring a hole forces nothing.
  ECHO = floe.mkSig {
    name = "ECHO";
    as = "echo";
    description = "Fixture: echoes back what a hole resolved to, so a silent non-resolution fails.";
    fields.v = T.str;
  };

  # Two consumers of one signature, one reading a portable field and one a
  # local one: the same external is correct for the first and an error for
  # the second.
  mkConsumer =
    { name, field }:
    floe.mkFloe {
      inherit name;
      summary = "Fixture floe for a test suite.";
      requires.ingress = MIXED_INGRESS;
      provides.echo = ECHO;
      modules = [
        (
          { config, ... }:
          {
            config.floe.provides.echo.v = config.floe.requires.ingress.${field};
          }
        )
      ];
    };

  consumer = mkConsumer {
    name = "consumer";
    field = "baseDomain";
  };
  localConsumer = mkConsumer {
    name = "local-consumer";
    field = "className";
  };

  # `baseDomain` travels. `className` is an ingress class registered in the
  # cluster that provided it and means nothing anywhere else.
  MIXED_INGRESS = floe.mkSig {
    name = "INGRESS";
    as = "ingress";
    description = "Fixture: an ingress whose fields are half portable and half link-local.";
    fields = fixture.sigs.INGRESS.fields // {
      className = T.local T.str;
    };
  };

  # Every field local, so nothing in it would be readable here.
  ALL_LOCAL = floe.mkSig {
    name = "ALL_LOCAL";
    as = "allLocal";
    description = "Fixture: every field local, so the signature cannot cross a link boundary at all.";
    fields.crdKinds = T.local (T.listOf T.str);
  };

  externalIngress = {
    sig = MIXED_INGRESS;
    origin = "cluster 'mgmt'";
    value = {
      baseDomain = "elsewhere.example.com";
      className = "nginx";
      # The token shape `mkDeferred` produces, written out: the constructor
      # is bound to a unit of the link, and this value comes from outside one.
      address = {
        __deferred = true;
        source = "mgmt/ingress";
        path = [ "address" ];
        phase = "post-apply";
      };
    };
  };

  withExternal =
    ext:
    floe.link {
      units.consumer = consumer.instantiate { };
      scope = ext;
    };

  linkedExternally = withExternal { ingress = externalIngress; };

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

  # An eval edge says A needed B's config to render, one per contributor for
  # a collection. Two pairs are cycles laziness carries; the deploy edge is
  # derived, from a deferred token the link-time scan found in `out.k8s`.
  testEdges = {
    expr = edges;
    expected = [
      "deploy:grafana->ingress via status.loadBalancer.ip"
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

  # ---- externals ----------------------------------------------------------

  # A hole nothing in this link provides, answered anyway: the value crossed
  # the boundary, was sealed, reached `config.floe.requires`, and came out.
  testAScopeProvideAnswersAHole = {
    expr = linkedExternally.provides.consumer.echo.v;
    expected = "elsewhere.example.com";
  };

  # A link with the hole and no external is still the error it always was.
  # The paired negative, so the test above cannot pass for the wrong reason.
  testWithoutTheScopeTheHoleIsUnfilled = {
    expr = fails (withExternal { }).provides.consumer.echo.v;
    expected = true;
  };

  # Sealed like any other provide. A value assembled outside this link is the
  # least likely place for a wrong shape to be noticed, and a body reading a
  # field that is not there fails far from the cause.
  testAScopeProvideIsSealedAgainstItsSignature = {
    expr =
      fails
        (withExternal {
          ingress = externalIngress // {
            value = removeAttrs externalIngress.value [ "className" ];
          };
        }).provides.consumer.echo.v;
    expected = true;
  };

  # Nearer wins: a unit of this link shadows a provider from the enclosing
  # scope. A cluster with its own gateway keeps it; one without takes the
  # lab's.
  testALocalProviderShadowsTheScope = {
    expr =
      (floe.link {
        units = {
          consumer = consumer.instantiate { };
          ingress = fixture.floes.nginxIngress.instantiate { baseDomain = "lab.example.com"; };
        };
        scope.ingress = externalIngress;
      }).provides.consumer.echo.v;
    expected = "lab.example.com";
  };

  # An external is not a node, so it is not in the graph and orders nothing.
  # Whatever backs it is applied by a different pass entirely, and an edge
  # here would be an edge to a node that does not exist.
  testAScopeProvideAddsNoEdgeAndNoNode = {
    expr = {
      nodes = linkedExternally.graph.nodes;
      edges = linkedExternally.graph.edges;
    };
    expected = {
      nodes = [ "consumer" ];
      edges = [ ];
    };
  };

  # `wiring.one` is what every existing reader walks to derive order, so an
  # externally-resolved hole must not appear in it. It appears in `external`
  # instead, which is how a reader that *does* care can ask.
  testScopeHolesAreReportedApartFromLocalOnes = {
    expr = {
      one = linkedExternally.wiring.one.consumer;
      scope = linkedExternally.wiring.scope.consumer;
    };
    expected = {
      one = { };
      scope.ingress.scope = "ingress";
    };
  };

  # ---- locality ------------------------------------------------------------

  # A local field is ordinary inside the link that produced it. Locality is
  # about which link is *reading*, so it can never be a check on the value.
  testALocalFieldIsOrdinaryAtHome = {
    expr =
      (floe.link {
        units = {
          ingress = fixture.floes.nginxIngress.instantiate { baseDomain = "lab.example.com"; };
          local-consumer = localConsumer.instantiate { };
        };
      }).provides.local-consumer.echo.v;
    expected = "nginx";
  };

  # And an error the moment it is read through an external, because there is
  # no value that would be right — not because this one failed a check.
  testReadingALocalFieldAcrossALinkIsAnError = {
    expr =
      fails
        (floe.link {
          units.local-consumer = localConsumer.instantiate { };
          scope.ingress = externalIngress;
        }).provides.local-consumer.echo.v;
    expected = true;
  };

  # The paired positive, and the reason this is per field: the *same* external
  # read for something that does travel is correct. Without it the throw above
  # could be any failure at all.
  testAPortableFieldOnTheSameScopeProvideStillReads = {
    expr = linkedExternally.provides.consumer.echo.v;
    expected = "elsewhere.example.com";
  };

  # Nothing portable in it, so a hole resolved against it resolves to nothing
  # usable. Refused up front, and derived from the fields, so a signature that
  # gains a routed address starts crossing on its own.
  testAnAllLocalSignatureIsRefusedFromScope = {
    expr =
      fails
        (floe.link {
          units.consumer = consumer.instantiate { };
          scope = {
            ingress = externalIngress;
            other = {
              sig = ALL_LOCAL;
              origin = "cluster 'mgmt'";
              value.crdKinds = [ "kind:example.io/Widget" ];
            };
          };
        }).provides;
    expected = true;
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
        as = "x";
        fields = { };
      }
    );
    expected = true;
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

  # Nix cannot read comments, so without this a floe's header prose reaches no
  # tool and the only machine-readable thing about it is its name.
  testAFloeMustSayWhatItInstalls = {
    expr = fails (floe.mkFloe { name = "x"; });
    expected = true;
  };

  testAnOutputKindMustSayWhatItCarries = {
    expr = fails (
      floe.mkOutputKind {
        name = "x.y";
        schema = T.any;
      }
    );
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
}

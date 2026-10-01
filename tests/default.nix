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
    shape = T.record { v = T.str; };
  };

  # A consumer echoes back what its hole resolved to, so a silent
  # non-resolution fails the test rather than passing it quietly.
  ECHO = floe.mkSig {
    name = "ECHO";
    canonicalName = "echo";
    description = "Fixture: echoes back what a hole resolved to.";
    shape = T.record { v = T.str; };
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
        shape = T.record { };
      }
    );
    expected = true;
  };

  testASignatureMustSayWhatItIsCalled = {
    expr = fails (
      floe.mkSig {
        name = "X";
        description = "d";
        shape = T.record { };
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
}

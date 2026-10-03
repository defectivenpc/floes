# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Nothing has been released yet, so this describes the delta from the
implementation this was extracted from —
[catallaxy](https://github.com/defectivenpc/catallaxy)'s `lib/floe-core`,
which no longer exists there: that repository now takes this one as a flake
input. Surfaces added and then removed before any release are not listed;
the ADRs keep their reasoning.

### Added

- **`collects`**, a hole arity taking every provider in the link, keyed by
  the unit that provided it, and possibly empty. The consumer folds it —
  nothing merges in the linker, so there are no lattice types and no
  order-independence obligation. One eval edge per contributor and no
  install edge: a consumer collecting declarations does not need its
  contributors running.

- **`link` checks that a provider answers the requirer's signature.**
  Resolution keys on a signature's `name`, a bare string, and nothing
  compared the shapes behind it — so two definitions of one name linked
  cleanly and the consumer died on Nix's `attribute 'port' missing`, several
  frames away, naming no floe, no field and no provider, and not catchable
  by `tryEval`. The provider must now be a width-supertype of the requirer,
  checked from headers before anything evaluates, with one asymmetry: a
  concrete provider answers a `T.deferred` requirer and the reverse is
  refused. This is also the signature-evolution rule, which is why there is
  no version field.
  [ADR 0007](docs/adr/0007-a-provider-must-answer-the-requirers-signature.md)

- **`instance.bind { <hole> = "<unit>"; }`**, so a deployer can say which
  provider a hole means when there are two. Spelled `<unit>` or
  `<unit>/<provide>`. It relieves one consumer and does not make the
  signature many-provider, so a second provider still breaks every
  `requires` of it.

- **`link { defaults = { SIGNATURE = "<unit>"; }; }`**, the same decision
  made once for a whole link, so adding a second provider of something stops
  being a breaking change to every existing consumer. Applied only where a
  unit gave no `.bind` of its own.

- **`mkFloe { body = { inputs, requires, collects, floe }: …; }`**, a plain
  function as an alternative to `modules`, for a floe that does not need the
  module system's merge. About 30% cheaper per floe.

- **`mkFloe { singleton = true; }`**, for a floe whose body writes fixed
  paths instead of keying them by `floe.name`. Two instances would emit
  identical output, and identical values merge without complaint, so nothing
  downstream could catch it.

- **`T.derivedFrom <sig> <inner>`**, marking a field its provider computed
  by folding a collection. `link` refuses that one field to any peer
  contributing to the same collection, before anything evaluates. This
  converts `infinite recursion encountered` — which named nothing and which
  `builtins.tryEval` could not even catch — into an error naming both floes,
  the collection and the field. Per field, not per hole.

- **`T.package`**, a derivation or the store path it coerces to: the one way
  something built crosses a floe boundary. A package **set** is not a
  signature — a floe takes the packages it needs as ordinary inputs, one at
  a time, because a package set can be neither hashed for a cache key nor
  serialised. [ADR 0008](docs/adr/0008-per-floe-eval-stays-cacheable.md)

- **`narrows`**. A narrowing promises no more than what it narrows, which is
  what a distribution's table of "this may cross a link boundary" holds —
  and nothing was checking it, so a form that accidentally _widened_
  surfaced where a peer read the field that was not there. The same relation
  compatibility decides between a requirer and a provider, pointed inward.

- **`link.deferredSites` and `link.deferredRetrievals`**, so a backend can
  find the values it must reify: one site per token that reached output, as
  `{ unit; out; at; token; }`, where `at` is a list of keys because output
  keys contain dots. Core ships no substitution function deliberately — a
  ConfigMap, a Secret, an annotation, a file and an HTTP lookup are five
  mechanisms for one job, and choosing in core would choose for every
  distribution at once.

- **`link.cycles`**, the strongly-connected components of the eval graph.
  Derivable from headers, which is why RFC 0001's open question 3 is
  answered "derived" rather than "declared", and what a distribution needs
  in order to refuse cycles as a policy — which core deliberately does not.

  Building it measured the caching argument it exists for, and the number is
  not what that argument assumed: the twenty-nine-unit fleet is **one
  component of twenty-six**, so the cache-unit partition is four. A
  namespace with an owner is a cycle through nearly everything. An eval edge
  is per hole where the dependency is per field, and that is where a real
  answer would start.

- **`link.providersOf "<SIG>"`**, returning every unit in the link that
  answers a signature, as `{ instName; provideName; value; }`.

### Changed

- **`requiresOptional` is now `optional`, and it resolves only when a
  deployer names the provider** — by `.bind` or by the link's `defaults`. A
  link holding an unnamed provider for an optional hole is an error naming
  the candidate.

  The rename is mechanical; this is not. Presence used to be consent: a
  cluster holding kanidm wired OIDC into every consumer that asked, and a
  deployer wanting local accounts for one of them had no way to say so and
  no sign it had happened. Now adding a floe to a link can never silently
  change another floe's output — the property `requires` gets for free by
  erroring on a second provider.
  [ADR 0009](docs/adr/0009-an-optional-hole-resolves-only-when-named.md)

- **A deferred value now says where it will be readable.** `T.runtime`
  marked a value as not-yet-existing and produced a token carrying a
  meaningless `path` and a constant `phase`, so RFC 0001's "backends
  substitute token sites" was not implementable against it. The type is
  `T.deferred`, `mkRuntime` is `mkDeferred`, and the _provider_ declares a
  **retrieval** — an ordinary signature describing where the value lands:

  ```nix
  mkDeferred SECRET_REF { namespace = "cert-manager"; name = "ca-tls"; key = "ca.crt"; }
  ```

  Core checks the ref, records the signature's name, and never looks inside.
  The provider declares it rather than the signature's field because
  `DATABASE.password` is a Secret in Kubernetes and a file on NixOS: one
  signature, two mechanisms. The token's `path` and `phase` are gone —
  `path` was only the deploy edge's label, which is now the retrieval name,
  and apply order was always _derived_ as `link.phases`.
  [ADR 0005](docs/adr/0005-the-provider-declares-the-retrieval.md)

- **`mkOutputKind` is gone; `mkSig` covers both.** A signature already _was_
  an output kind — sealing built a record out of a signature's fields, which
  is exactly what a kind's schema was. `out.<canonicalName> = someSig`.

- **`mkSig`'s `as` is now `canonicalName`**, and `link` enforces it: no
  single hole or provide name may mean two different signatures. Not the
  reverse — a floe may hold a primary and a replica on one signature.

- **`mkSig`'s `fields` accepts either an attrset of `T`s or a bare `T`**,
  dispatching on whether the argument is itself a type, so one constructor
  serves a narrow interface and an opaque `T.attrsOf T.any` output alike. An
  attrset is wrapped in `T.record` for you.

- **Input values are validated lazily, per input.** A declared input whose
  supplied value is badly typed, and which the body never reads, no longer
  fails at instantiate time. This matches NixOS, which was measured rather
  than assumed: a badly-typed `networking.hostName = 12345` sits in a real
  system evaluation and never errors unless something reads it. Floe was
  stricter than the system it is modelled on.

  The _shape_ of an instantiate call stays eager — an undeclared key or a
  missing required input is refused whether or not anything reads it.

### Removed

- **`link`'s `scope`, and `T.local` / `isUncrossable` with it.** The largest
  unexercised machinery in the library, and the reason `T` carried a
  locality concept the examples never needed.

  What replaces it needs no library feature: a value from outside becomes an
  ordinary unit of the consuming link, providing it under the signature the
  boundary allows. What may cross is a table the distribution writes down
  and checks with `narrows`, rather than a marking on every field.
  [`docs/migrating.md`](docs/migrating.md) says how to move a call site.

### Fixed

- **A derivation in `out` no longer takes the evaluation down.** A
  derivation is an attrset whose `out` is itself, so the token scan walked
  it until the stack ran out — and a stack overflow is not catchable, so
  reading `link.deferredSites` in any link with a package in its output was
  an uncatchable crash. Every NixOS module writing
  `environment.systemPackages` hits it.

- **Interpolating a deferred value is now floe's error, and testable.** It
  was Nix's "cannot coerce a set to a string", which named no floe, arrived
  before anything typed saw the value, and escaped `builtins.tryEval` — so
  it was the one deliberate mistake in `examples/` that no test could hold.
  The token carries a `__toString` that throws. RFC 0001's open question 1
  is answered: a deferred value does not propagate through interpolation, it
  refuses.

  The cost, deliberately taken: `builtins.toJSON` prefers `__toString`, so a
  token reaching the serialised IR throws too — the same refusal, since a
  token there means a backend is about to ship a placeholder.

- **A `.bind` naming a collected hole is refused rather than ignored.** A
  collection's arity is every provider, so there is nothing for a binding to
  choose — and a deployer who wrote one believed it did something.

- **A hole name on both `requires` and `optional` is refused.** Both resolve
  into one `requires` attrset, so one would be dropped with nothing saying
  which.

- **`checkInputs` ran a whole `lib.evalModules` per floe** to validate one
  attrset of deployer-supplied values. It now calls
  `lib.modules.mergeDefinitions` per option — the same module-system
  machinery at the granularity the job has — for 6 MB against 107 MB on a
  thousand floes of fifteen inputs, and about 2.5 MB per declared input
  rather than 5.5 MB. Submodule defaults, `mkIf`, `mkForce` and `mkOrder`
  all still work, because that is nixpkgs' own code doing it.
  [ADR 0004](docs/adr/0004-borrow-the-module-system-per-option.md)

- **Hole resolution was O(units × holes).** Two separate passes each
  rescanned every unit's provides once per hole. Indexing the provides once
  took a thousand-unit link from 1.14 s / 586 MB to 0.15 s / 129 MB and made
  it linear. `bench/run.sh` is the measurement.

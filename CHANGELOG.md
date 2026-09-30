# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- **`mkOutputKind` is gone; `mkSig` covers both.** A signature already _was_
  an output kind — sealing built a record out of a signature's fields, which
  is exactly what a kind's schema was. `out.<canonicalName> = someSig`.
- **`mkSig`'s `fields` is now `shape`**, and takes a `T` directly rather
  than an attrset of them. One constructor then serves a narrow interface
  and an opaque `T.attrsOf T.any` output alike.
- **`mkSig`'s `as` is now `canonicalName`**, and `link` enforces it: no
  single hole or provide name may mean two different signatures. Not the
  reverse — a floe may hold a primary and a replica on one signature.
- **`T.deferred` is now `T.runtime`**, with `mkDeferred` → `mkRuntime` and
  `isDeferredToken` → `isRuntimeToken`.

### Added

- **`T.derivedFrom <sig> <inner>`**, marking a field its provider computed
  by folding a collection. `link` refuses that one field to any peer
  contributing to the same collection, before anything evaluates. This
  converts `infinite recursion encountered` — which named nothing and which
  `builtins.tryEval` could not even catch — into an error naming both floes,
  the collection and the field. Per field, not per hole.
- **`link { defaults = { SIGNATURE = "<unit>"; }; }`**, so adding a second
  provider of something stops being a breaking change to every existing
  consumer. Applied only where a unit gave no `.bind`.
- **`mkFloe { body = { inputs, requires, collects, floe }: …; }`**, a plain
  function as an alternative to `modules`, for a floe that does not need the
  module system's merge. About 30% cheaper per floe.
- **`mkFloe { singleton = true; }`**, for a floe whose body writes fixed
  paths instead of keying them by `floe.name`. Two instances would emit
  identical output, and identical values merge without complaint, so nothing
  downstream could catch it.

### Changed, and a deliberate loosening

- **Input values are now validated lazily, per input.** A declared input
  whose supplied value is badly typed, and which the floe body never reads,
  no longer fails at instantiate time. This matches NixOS, which was
  measured rather than assumed: a badly-typed `networking.hostName = 12345`
  sits in a real system evaluation and never errors unless something reads
  it. Floe was stricter than the system it is modelled on.

  The _shape_ of an instantiate call stays eager — an undeclared key or a
  missing required input is refused whether or not anything reads it.

### Removed

- **`requiresOptional`.** An arity with no caller, in its second design.
- **`link`'s `scope`, and `T.local` / `isUncrossable` with it.** The largest
  unexercised machinery in the library, and the reason `T` carried a concept
  the examples never needed. This breaks catallaxy's lab/cluster nesting.
  [`docs/migrating.md`](docs/migrating.md) says why and what to do.

### Fixed

- **`checkInputs` ran a whole `lib.evalModules` per floe** to validate one
  attrset of deployer-supplied values. It now calls
  `lib.modules.mergeDefinitions` per option — the same module-system
  machinery at the granularity the job has — for 6 MB against 107 MB on a
  thousand floes of fifteen inputs, and about 2.5 MB per declared input
  rather than 5.5 MB. Submodule defaults, `mkIf`, `mkForce` and `mkOrder`
  all still work, because that is nixpkgs' own code doing it. See
  [ADR 0004](docs/adr/0004-borrow-the-module-system-per-option.md).
- **Hole resolution was O(units x holes).** `localProvidersOf` rescanned
  every unit's provides once per hole, and two separate passes did it.
  Indexing the provides once took a thousand-unit link from 1.14s / 586MB to
  0.15s / 129MB and made it linear. `bench/run.sh` is the measurement.

### Added

- **Extracted from [catallaxy](https://github.com/defectivenpc/catallaxy)**,
  where this was `lib/floe-core` and remains the layer the platform is built
  on. The library takes nothing but `nixpkgs.lib`; that repository's history
  has everything before this point, including two earlier implementations
  that preceded the design.

- **`collects`**, a third hole arity. Where `requires` takes exactly one
  provider and `requiresOptional` zero or one, a collection takes every
  provider in the link, keyed by the unit that provided it, and may be
  empty. The consumer folds it — nothing merges in the linker, so there are
  no lattice types and no order-independence obligation.

  It carries one eval edge per contributor and no install edge: a consumer
  collecting declarations does not need its contributors running.

- **`instance.bind { <hole> = "<unit>"; }`**, so a deployer can say which
  provider a hole means when there are two. Spelled `<unit>` or
  `<unit>/<provide>`. RFC 0001 §6 always intended this — it is what makes
  exactly-one coherence tolerable — and it was the half never built.

  It relieves one consumer. A binding resolves a hole; it does not make the
  signature many-provider, so a second provider still breaks every
  `requires` of it.

- **`link.providersOf "<SIG>"`**, returning every unit in the link that
  answers a signature, as `{ instName; provideName; value; }`.

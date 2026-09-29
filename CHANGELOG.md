# Changelog

All notable changes to this project will be documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

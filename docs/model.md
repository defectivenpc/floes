# The Model

Floe borrows its vocabulary, and knowing the source explains most of it at
once. Floe is Haskell's [Backpack](https://plv.mpi-sws.org/backpack/), a
mixin module system, applied to NixOS modules rather than to Haskell
modules, with sealing from ML.

| Here                        | There                                                                   |
| --------------------------- | ----------------------------------------------------------------------- |
| **Signature**               | a Backpack signature (`.hsig`): an interface with no implementation     |
| **Hole**                    | a hole: an unfilled signature a unit requires                           |
| **Link**                    | mixin linking: matching requirements to implementations by name         |
| **`requires` / `provides`** | a unit's requirements and provisions                                    |
| **Instantiation**           | instantiating a unit by filling its holes                               |
| **Sealing**                 | ML's opaque sealing (`:>`): a structure seen only through its signature |

That correspondence is why the rules are what they are. A hole must be
filled by exactly one provider because mixin linking resolves **by name, not
by search**. A provided value is sealed because a signature is the _whole_
interface: if a consumer could read past it, the signature would not be one.

## The one word that diverges

Backpack calls the _definition_ a unit. Here a **floe** is the definition
and a **unit** is an instantiation of one, under the name a link gives it.
The divergence is deliberate and load-bearing: a floe can be instantiated
more than once in one link, so the thing a link keys on, and the thing
errors name, is the instance rather than the definition.

`examples/nixos/postgres.nix` is why it matters. `services.postgresql` is a
singleton option path, so two Postgres servers on one host cannot be
expressed with the nixpkgs module at all; that floe emits
`systemd.services.postgres-<unit>`, keyed by the link's name for the
instance, and two coexist.

## What this has that Backpack does not

Three things, each because infrastructure has a problem a compiler does not.

**`collects`**: a hole taking every provider rather than one. Backpack has
no fan-in, because a Haskell unit does not aggregate. A firewall owner
collecting a port claim from every service does, and the consumer folds the
collection: nothing merges in the linker, so there is no lattice and no
order-independence obligation.

**`T.deferred`**: a value that does not exist until after apply, from which
the linker derives a deploy edge and a phase. A compiler's inputs all exist;
a generated secret or an allocated address does not. The provider also
declares a **retrieval**, an ordinary signature saying where the value will
be readable, which is how one signature survives two domains with two
mechanisms.

**`T.derivedFrom`**: a field its provider folded out of a collection. The
linker withholds that one field from the peers feeding that fold, because
reading it there is a cycle through the fold. Backpack has nothing to say
about a unit reading back its own contribution.

## Closure, which is why nesting is not a separate mechanism

MixML's central result, and the reason the vocabulary holds at every level:
linking units yields a unit, so functor and structure are one notion.
Backpack inherits it, where a unit with holes is a unit and `include` builds
one from others. A floe takes `units` beside `body`, so a cluster that
includes chart floes and a lab that includes clusters are the same mechanism
rather than two, and a floe may include and define at once. `docs/adr/0006`
carries the argument and the two places this still diverges.

A link is still one fixpoint over one set of units, with no wider scope it
falls back to. An inclusion is a boundary, not a lookup path: `scope` was
the version that made it a second resolution path consulted when the first
failed, and `docs/adr/0003` deleted that.

## What it does not have

**Per-floe separate compilation.** Backpack type-checks a unit against its
holes with no implementation present. Here you check a floe by linking it
against stubs, because the check is on values at eval rather than on source.
`link.cycles` says why that is unlikely to change soon: in a real link the
components are large enough that a floe is rarely a unit of anything on its
own.

## Distributions

The library knows no domain. A **distribution** supplies the signatures its
floes speak, the output signatures they emit, whatever policies it enforces
at link, and the adapter that turns a link result into what its world wants.

[Catallaxy](https://github.com/defectivenpc/catallaxy) is one, for
Kubernetes: forty floes and five labs, and the thing that exercises this
library in anger. `examples/` holds two small ones, a NixOS probe and a
Kubernetes contrast, so development runs against more than one domain.

## Next

- [The mkFloe API](floe-api.md): the surface this describes.
- [RFC 0001](rfcs/0001-floes.md): the design it argues for, and its five
  open questions, four of which are now answered in place.

# Migrating

The library was extracted from catallaxy and then reviewed, which produced
one batch of breaking changes rather than a trickle. No aliases: there is
one known consumer, it has the same author, and carrying compatibility
weight for it would be the speculative generality the review was deleting.

## Mechanical

| Before                                                    | After                                                |
| --------------------------------------------------------- | ---------------------------------------------------- |
| `mkSig { as = "proxy"; … }`                               | `mkSig { canonicalName = "proxy"; … }`               |
| `mkSig { fields = { a = T.str; }; }`                      | `mkSig { shape = T.record { a = T.str; }; }`         |
| `mkOutputKind { name; description; schema; }`             | `mkSig { name; canonicalName; description; shape; }` |
| `out.<localName> = someKind`                              | `out.<canonicalName> = someSig`                      |
| `T.deferred T.str`                                        | `T.runtime T.str`                                    |
| `floe.mkDeferred [ … ]` (in a body)                       | `floe.mkRuntime [ … ]`                               |
| `floe.isDeferredToken`                                    | `floe.isRuntimeToken`                                |
| `config.floe.out.<k>` where `<k>` was a kind's local name | keyed by the signature's `canonicalName`             |

`link`'s result is unchanged except that `wiring.optional` and
`wiring.scope` are gone and `wiring.all` is new.

## Removed, with reasons

**`requiresOptional`.** An arity nobody used. RFC 0001 records that it
already replaced a `requiresMany` which was itself removed, so this is the
second design for a surface that never had a caller. If you need
zero-or-one, a `requires` plus a second link without that unit expresses it;
if that turns out to be wrong, it comes back with a use case attached.

**`link`'s `scope`, and `T.local` / `isUncrossable` with it.** This is the
painful one, and it is catallaxy's lab→cluster nesting. It was the largest
piece of unexercised machinery in the library: nothing in `examples/` used
`scope`, and `T.local` existed only so `scope` could refuse fields that mean
nothing in another link — which made `T` carry a concept the NixOS examples
never needed.

Untested code that shapes vocabulary is worse than absent code, so it went.
To bring it back, the condition is a worked multi-link example, not a
request: the reason it was deletable is that nobody could point at a test
that would have caught it breaking.

In the meantime, a nested link's parent facts can be passed as `inputs`.
That is worse — no locality checking, and the deployer threads them by hand
— and it is the honest state of things rather than a recommendation.

## Added

**`T.derivedFrom <sig> <inner>`.** Marks a field a provider computed by
folding its collection of `<sig>`. `link` refuses that one field to any peer
that contributes to the same collection, before anything evaluates. Mark
every field you compute from a `collects`; the failure it prevents is
otherwise `infinite recursion encountered` with nothing named, and not
catchable by `tryEval` either.

**`link { defaults = { SIGNATURE = "<unit>"; }; }`.** Which provider a hole
means when its consumer did not say. Applied only where a unit gave no
`.bind`, so ambiguity nobody decided is still an error. Add these when a
second provider of something appears: without them, that addition breaks
every existing consumer.

**`mkFloe { body = { inputs, requires, collects, floe }: { provides, out }; }`.**
An alternative to `modules`, for a floe that does not need the module
system's merge — which is most of them. About 30% cheaper. `provides` still
has to be _declared_ as well as returned, because the linker resolves holes
from headers before any body runs.

**`mkFloe { singleton = true; }`.** For a floe whose body writes fixed paths
rather than keying them by `floe.name`. Two instances of one would emit
identical output, and identical values merge without complaint, so the
deployer would get one of the thing with no error anywhere. Declare it, or
key the output by `floe.name` and gain the ability to instantiate freely.

## One new check to expect

`link` now refuses a link where **one hole or provide name means two
different signatures** — `requires.proxy` being `REVERSE_PROXY` in one floe
and `HTTP_PROXY` in another. Rename one to its signature's `canonicalName`.

Not the reverse: a floe may hold two holes on one signature, a primary and a
replica, so a signature is not pinned to a single name. The consequence
worth knowing is that two signatures which _want_ the same canonical name —
`DATABASE` and a hypothetical `DATABASE_V2`, both wanting `database` —
cannot both have it. One has to be `databaseV2`, and that is the intended
answer rather than a limitation to work around.

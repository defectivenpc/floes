# A provision's backing unit surfaces at the parent

A provider reference in `result.wiring` carries `backedBy` and
`backedProvide` when the providing unit is an inclusion: the unit inside it
that actually implements the provision, fully qualified, resolved through
nested inclusions. `instName` is untouched — it is who promised the value,
which is what resolution and every error message mean by a provider.

ADR 0010 surfaced an inclusion's inner _wiring_ at the parent because a
backend deriving install order read it and the parent dropped it. This is
the same sentence about an inclusion's _exports_. A consumer outside an
inclusion resolves against the inclusion, and a backend that asks the
provider for its artifacts finds an inclusion that only includes has none of
its own. The dependency has no target, the edge disappears, and the consumer
is free to be installed before the thing it needs — with nothing in the
graph saying otherwise and no error anywhere.

Catallaxy is where it showed, and it had been silent for as long as the
pattern existed. A cluster composed a platform inclusion — CRDs, an issuer,
a gateway — and placed its workloads beside it. Every workload requiring the
gateway lost its edge to it, so routes were ordered _before_ the Gateway
they attach to. Nobody noticed because Gateway API is eventually consistent:
the route is accepted, sits unresolved, and attaches when the Gateway lands.
The order was correct where it was correct by luck, which is not an ordering
constraint.

## Considered options

**The consumer names the inner unit.** `requires.gateway` resolves against
`platform`, so the deployer writes the ordering by hand. Rejected outright:
nothing may declare an ordering, which is the whole claim. It also asks a
consumer to know an inclusion's internals, which is what sealing is for.

**The backend prefix-matches.** Given a provider `platform`, order against
every artifact under `platform/`. Rejected because it is over-broad in a way
that can invent a cycle: a sibling outside the inclusion would wait on units
inside it that have nothing to do with the provision, including any that
depend on the sibling.

**Resolve it during the preflight**, in the provider index. Rejected because
it cannot be done there — `units` is a function of a floe's inputs, so the
set of units inside an inclusion is not known until the fixpoint has
resolved its holes. That is the same constraint that makes an inclusion
declare its holes rather than infer them.

## Consequences

`exportOriginOf` is on the result, so a backend can ask the question
directly rather than reading it off `wiring`. It answers for a non-inclusion
too, with the unit and provide it was given.

One level of qualification reaches every depth, because the inner result
answers for its own inclusions — the argument `innerWiringOf` already makes.
An inclusion that re-exports from an inclusion resolves to the unit at the
bottom of the chain.

Install order moves in every composition that placed consumers beside an
inclusion, which is the point: those are edges that should have existed.
Anything pinning a derived order as a value will change, and the diff is the
edges arriving.

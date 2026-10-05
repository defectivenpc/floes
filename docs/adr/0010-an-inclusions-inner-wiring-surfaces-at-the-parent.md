# An inclusion's inner wiring surfaces at the parent

`link`'s result carried `wiring` keyed by the units of _that_ link, so after
[ADR 0006](0006-a-link-can-be-a-unit.md) a unit inside an inclusion had no
entry: `wiring.one.<inclusion>` describes the inclusion's own holes, not its
units'. Every other per-unit view already spans the nesting — `out` is keyed
`<inclusion>/<innerUnit>`, `phases` by leaves at any depth, `graph` by nodes
at any depth — so `wiring` was the one view that stopped at the boundary,
and the consequence was that anything deriving a per-unit fact from a
resolution lost it for everything inside an inclusion.

`wiring.{one,optional,all}` are now keyed by the unit whose hole it is at
any depth, with each provider's `instName` qualified the same way. So is
`floeNames`, which is new and answers the other question a per-unit consumer
asks: _which floe is this unit an instance of._ A unit name is the
deployer's, an inner unit's definition is not reachable through the
inclusion holding it, and a rule of the form "every floe declares the images
its manifests pull" needs the name to find the declaration it is checking
against.

## Why it is the parent's business at all

A reader might expect the opposite: an inclusion seals, so why does the
parent see inside it? Because sealing governs _values_, not the graph. The
parent already sees every inner unit's output, every inner node and every
inner eval edge, and it has to: a backend wants one bucket, and `phases`
must span the nesting because an inclusion is not a thing that applies — its
units are. `wiring` says which provider answered which hole, which is the
same class of fact as the edge that encodes it, and no sealed value crosses
with it.

The adopter ADR 0006 was written for makes the case concrete. Catallaxy's
elaborator reads `wiring.one.<unit>` to derive one bundle's install-order
edges to another's, at provide granularity, and a cluster that becomes an
inclusion of component floes would have every one of those edges disappear.
The alternatives were worse: re-linking a cluster's units at top level to
lower it evaluates every floe twice and makes two paths' output a thing to
check, and deriving the edges from `graph.edges` instead loses provide
granularity, since an eval edge carries the hole but not which provide
answered it.

## Synthetic units appear on neither side

A hole the parent filled resolves, inside, to a synthetic unit carrying that
value. Those entries are dropped — as a provider and as a key — for the
reason the edge to one is dropped: the value is the parent's, the parent's
own entry against its own hole already says so, and keeping it would speak
in terms of a node nothing else mentions. Membership in the inner link's
`graph.nodes` is the test, because the synthetic units are the only units
that set excludes.

`collects` filters the list rather than dropping the hole, since one
collection can be answered from inside and outside at once.

## Consequences

One level of qualification reaches every depth, because an inner result's
own `wiring` and `floeNames` have already been through it — the same
recursion `leaves` and `deferredSites` rely on, and the reason the test for
this covers two levels rather than one.

A policy that iterates `wiring` now sees inner units. That is the point, but
it is a behaviour change for any policy written against the flat keys: one
that asserted something per unit will now assert it per unit at every depth,
which is either what it wanted or a policy that needs to say
`!lib.hasInfix "/" u`.

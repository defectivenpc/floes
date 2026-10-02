# A link can be a unit, which is what `scope` should have been

`docs/adr/0003` deleted `link`'s `scope`, `T.local` and `isUncrossable` on
the grounds that nothing in `examples/` used them. That was true, and it was
the wrong check. Catallaxy's own link call site passes `scope`
(`modules/lab/cluster.nix`, `inherit scope catalogue`) and its signatures
carry `T.local` on 81 fields. The requirement — a lab holding clusters,
where a value can reach inward without the inner link knowing the outer one
exists — never stopped being real. Only the mechanism was wrong.

An **inclusion** replaces it: a floe whose body is a link. It therefore has
`inputs`, `.instantiate`, `.bind` and `singleton` already, declares
`requires`/`collects`/`provides`/`out` like anything else, and is resolved
by the rules that were already there.

## Why this is not ADR 0003 reversed

`scope` was three concepts doing one job. It was a side-channel attrset with
its own resolution path — `scopeProvidersOf`, consulted only after local
providers failed — so a hole resolved by two different mechanisms depending
on where its answer lived. `T.local` existed so that `scope` could refuse
fields meaning nothing in another link. `isUncrossable` existed so that
`T.local` had teeth. The deletion of all three stands.

What comes back is the requirement, under one mechanism that was already in
the model: Backpack's `include`, which `docs/model.md` records as the piece
with no counterpart here, and which presets were a private stand-in for.

## What crosses, and why `T.local` is still gone

An inclusion exports a declared subset of what its units provide, and the
export is itself a sealing step. So a value meaningful only inside is kept
inside by re-exporting under a narrower **export signature** and letting
sealing drop the rest.

This was not the first answer. The first was that per-signature export made
`T.local` unnecessary outright, and that is false: locality is per _field_,
and catallaxy's signatures are genuinely mixed. `API_GATEWAY` carries
`baseDomain` beside a `parentRef` naming an object in one cluster;
`X509_ISSUANCE` carries `publicIssuer` — whether a browser will trust what
this signs, true anywhere — beside an `issuerRef` whose own comment says a
Certificate elsewhere naming it stays pending forever.

The export signature handles exactly that, at the boundary rather than on
the type, and the inner floes do not change. The cost is one extra signature
name per concept that actually crosses a link boundary. That is a small set:
a field marked local in a signature that never crosses was marking a
boundary which did not exist.

## Inner holes stay open

An inclusion declares the holes its units leave unfilled, on the ordinary
surfaces with the ordinary arities, and the parent fills them. This is the
half that makes inclusion worth building rather than a convenience: a
cluster with an open `SECRET_STORE` is reusable across labs, and a lab can
_supply_ its clusters instead of only reading from them. A closed-link
inclusion would have left catallaxy's cross-cluster secret wiring where it
is now — hand-written in the module layer, checked by hand-written
`assertions` that both sides derived the same address, which is the error
class floe exists to move to link time.

**How a parent's value reaches the units inside is the part worth
recording.** Each filled hole becomes a _unit_ in the inner link that
provides what the parent resolved it to. That is the whole mechanism, and it
is why this is not `scope` wearing a new word: `scope` was a second
resolution path consulted when the first one failed, so a hole resolved by
different rules depending on where its answer lived. An injected value is a
provider like any other, with a real eval edge pointing at it, and
resolution gained nothing to special-case. A collected hole becomes one unit
per contributor, so the collector inside sees the same fan-in the parent did
rather than one merged value.

Those units are an implementation device and are filtered out of everything
a reader or a backend sees. The edge they stand for is emitted at the parent
level instead, where it is a true statement about the inclusion's own hole.

`withheld` needed no change at all: an inclusion declares `collects` like
any floe, so a parent contributing to an inner collection and reading the
fold is refused by the check that was already there.

## Consequences

Output propagates to the parent with unit names qualified by the inclusion
path (`app/cert-manager`), because a backend wants one bucket and `graph`
and `phases` have to span the nesting. So a `deferredSite`'s `unit` becomes
a path rather than a name, and `phases` is keyed by what emits — an
inclusion is not a thing that applies, its units are.

A deferred token's `source` is rewritten as it crosses, in the same function
that qualifies unit names, because `mkDeferred` binds `source` at body-eval
time when the inner link cannot know it will be included. Only for a token
minted _inside_, though: one that reached an inner unit from the parent
already names a unit the parent knows, and qualifying that invents a node
that does not exist. The same trap caught the inner graph's deploy edges,
which are simply dropped — `deferredSites` is flattened to every depth and
the parent re-derives every deploy edge from it, so keeping the inner ones
would duplicate all of them and misname some.

**`singleton` stays per link**, which contradicts an earlier draft of this
decision and is the one thing building it changed. The check exists because
two instances writing identical fixed paths merge silently wherever that
output lands. Two inner links are two _apply targets_ — two clusters, two
machines — so one nginx in each is correct and refusing it would be a bug.
The output keys differ (`app/nginx`, `web/nginx`) precisely because the
destinations do.

The lesson worth keeping from 0003 is narrower than the one it drew. "Could
anyone point at a check that would have caught this breaking?" is the right
question; "no check in this repository" is not the same answer as "no check
anywhere". The extracted library's consumer lives in another repository, and
that is where the check had to be looked for.

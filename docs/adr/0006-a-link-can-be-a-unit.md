# A link can be a unit, which is what `scope` should have been

> **Status: withdrawn, then restored on the theory.** This shipped, came out
> again, and is back. The withdrawal and the restoration are both worth
> reading, because the second answers the first rather than overruling it.
>
> **Why it came out.** Two reasons. An inclusion was a floe without a body,
> which made "floe" two kinds of thing: every other surface a floe has is a
> declaration about one implementation, and this one replaced the
> implementation with a link, so `mkFloe` grew an argument an author must
> not set in order for `mkInclusion` to set it. And nothing adopted it.
> Catallaxy, the repository whose `scope` call site it was built to replace,
> ported without it, because a lab does not have to be a link over its
> clusters.
>
> **Why it is back.** The first objection was itself a divergence from the
> theory, recorded three sections down as "An inclusion cannot also have a
> body" and admitted there to be "a simplification with no argument behind
> it beyond less code". MixML and Backpack both let a unit include _and_
> define. Taking them at their word dissolves the objection rather than
> accepting it: `mkFloe` gained `units` and `exports` as ordinary surfaces
> beside `body` and `modules`, a floe may now do either or both, and the
> argument an author must not set is gone along with `mkFloeWith` and
> `mkInclusion`. One constructor, one kind of floe, and less surface than
> the version that was withdrawn.
>
> The second objection is answered by an adopter with the three-level shape
> this was always for: chart floes, a cluster floe that includes them, a lab
> that includes the clusters.
>
> **The flat mechanism still works and is still right for some cases.** A
> value from outside can become an ordinary _unit_ of the consuming link,
> providing it under the signature the boundary allows, with no library
> feature at all. `docs/migrating.md` shows it. Inclusion is what you reach
> for when the boundary is a reusable component with open holes; the flat
> form is what you reach for when it is one value crossing once.

`docs/adr/0003` deleted `link`'s `scope`, `T.local` and `isUncrossable` on
the grounds that nothing in `examples/` used them. That was true, and it was
the wrong check. Catallaxy's own link call site passes `scope`
(`modules/lab/cluster.nix`, `inherit scope catalogue`) and its signatures
carry `T.local` on 81 fields. The requirement never stopped being real: a
lab holding clusters, where a value can reach inward without the inner link
knowing the outer one exists. Only the mechanism was wrong.

An **inclusion** replaces it: a floe whose body is a link. It therefore has
`inputs`, `.instantiate`, `.bind` and `singleton` already, declares
`requires`/`collects`/`provides`/`out` like anything else, and the rules
that were already there resolve it.

## Why this is not ADR 0003 reversed

`scope` was three concepts doing one job. It was a side-channel attrset with
its own resolution path, `scopeProvidersOf`, consulted only after local
providers failed, so a hole resolved by two different mechanisms depending
on where its answer lived. `T.local` existed so that `scope` could refuse
fields meaning nothing in another link. `isUncrossable` existed so that
`T.local` had teeth. The deletion of all three stands.

The requirement comes back, under one mechanism that was already in the
model: Backpack's `include`, which `docs/model.md` records as the piece with
no counterpart here, and which presets were a private stand-in for.

## What crosses, and why `T.local` is still gone

An inclusion exports a declared subset of what its units provide, and the
export is itself a sealing step. So you keep a value meaningful only inside
by re-exporting under a narrower **export signature** and letting sealing
drop the rest.

This was not the first answer. The first was that per-signature export made
`T.local` unnecessary outright, and that is false: locality is per _field_,
and catallaxy's signatures are mixed. `API_GATEWAY` carries `baseDomain`
beside a `parentRef` naming an object in one cluster; `X509_ISSUANCE`
carries `publicIssuer` (whether a browser will trust what this signs, true
anywhere) beside an `issuerRef` whose own comment says a Certificate
elsewhere naming it stays pending forever.

The export signature handles that, at the boundary rather than on the type,
and the inner floes do not change. The cost is one extra signature name per
concept that crosses a link boundary. That is a small set: a field marked
local in a signature that never crosses was marking a boundary which did not
exist.

## Inner holes stay open

An inclusion declares the holes its units leave unfilled, on the ordinary
surfaces with the ordinary arities, and the parent fills them. This is the
half that makes inclusion worth building rather than a convenience: a
cluster with an open `SECRET_STORE` is reusable across labs, and a lab can
_supply_ its clusters instead of only reading from them. A closed-link
inclusion would have left catallaxy's cross-cluster secret wiring where it
is now: hand-written in the module layer, checked by hand-written
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

Those units are an implementation device, and nothing a reader or a backend
sees includes them. The edge they stand for surfaces at the parent level
instead, where it is a true statement about the inclusion's own hole.

`withheld` needed no change: an inclusion declares `collects` like any floe,
so the check that was already there refuses a parent contributing to an
inner collection and reading the fold.

## Where this diverges from the theory it borrows from

MixML's central result is that composition is **closed**: a mixin has
imports and exports, linking mixins yields a mixin, and functor and
structure are one notion. Backpack inherits it: a unit with holes is a unit.
An inclusion being a floe is that property, and it holds at depth: an
inclusion holds an inclusion, and a test pins two levels because one cannot
tell an inner link's nodes from its leaves.

Three divergences, recorded because a reader who knows the theory will look
for them.

**Holes are declared, not inferred.** Backpack computes an including unit's
holes as the holes of what it includes minus what is filled. Here `units` is
a function of `inputs`, so nothing knows what is inside until something
evaluates, and a floe's interface has to be readable from its header before
anything does. Inference would cost that property, which is the one that
makes a link's wiring checkable without running it. The price is that the
declaration can drift from the units, in both directions: an under-declared
hole is the unfilled-hole error, and an over-declared one is refused too,
because a hole nothing reads asks a deployer to wire a value that changes
nothing.

**Nothing is exported by default.** Backpack re-exports an included unit's
provisions and thins by hand; an inclusion exports nothing without
`exports`. That is ML rather than Backpack, and consistent with sealing
being the thing floe takes from ML: for infrastructure, what crosses a
cluster boundary should be a decision rather than a default.

**An inclusion cannot also have a body.** _Closed: it can._ In both MixML
and Backpack a unit may include _and_ define, and the first version of this
refused it as a simplification with no argument behind it beyond less code.
That restriction turned out to be the thing that made "floe" two kinds of
thing and got the whole feature withdrawn, so closing it was the condition
of bringing it back. `units` and `exports` are ordinary `mkFloe` surfaces
beside `body` and `modules`.

The two halves meet without a merge rule, because output is keyed by unit: a
floe's own fragment lands under its own name and its units' land under
`<thisFloe>/<innerUnit>`, so the keys are disjoint by construction. The same
argument `systemd.services.<name>` gets. Provides needed one rule, since
both halves could answer the same name: a provide answered by an export
_and_ by the body is refused, for the reason two providers of one signature
are. The values may agree today, and nothing would say which the deployer
read.

One more, because it catches readers out: **flattening is not a no-op.**
Linking `A, B` as an inclusion and then with `C` is not the same as linking
`A, B, C`, because the inclusion seals. Mixin linking in MixML is
associative; this is not, and that is sealing working rather than failing.

## Consequences

Output propagates to the parent with unit names qualified by the inclusion
path (`app/cert-manager`), because a backend wants one bucket and `graph`
and `phases` have to span the nesting. So a `deferredSite`'s `unit` becomes
a path rather than a name, and `phases` is keyed by what emits: an inclusion
is not a thing that applies, its units are.

`link` rewrites a deferred token's `source` as it crosses, in the same
function that qualifies unit names, because `mkDeferred` binds `source` at
body-eval time when the inner link cannot know it will be included. Only for
a token minted _inside_, though: one that reached an inner unit from the
parent already names a unit the parent knows, and qualifying that invents a
node that does not exist. The same trap caught the inner graph's deploy
edges, which it drops: `deferredSites` is flattened to every depth and the
parent re-derives every deploy edge from it, so keeping the inner ones would
duplicate all of them and misname some.

**`singleton` stays per link**, which contradicts an earlier draft of this
decision and is the one thing building it changed. The check exists because
two instances writing identical fixed paths merge without complaint wherever
that output lands. Two inner links are two _apply targets_ (two clusters,
two machines) so one nginx in each is correct and refusing it would be a
bug. The output keys differ (`app/nginx`, `web/nginx`) because the
destinations do.

The lesson worth keeping from 0003 is narrower than the one it drew. "Could
anyone point at a check that would have caught this breaking?" is the right
question; "no check in this repository" is not the same answer as "no check
anywhere". The extracted library's consumer lives in another repository, and
that is where to look for the check.

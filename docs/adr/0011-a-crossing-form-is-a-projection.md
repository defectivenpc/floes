# A crossing form is a projection

The form of a signature a peer across a boundary may read is the full
signature with fields dropped, built by `project` and derived from the one
definition. It is not a second signature written beside the first, and not a
table joining the two.

A narrowing is what an inclusion's `exports` already does — the signature in
`provides` is usually narrower than the one inside, and that is how a value
meaningful only in here stays in here. What was missing is a constructor
that produces one. `narrows` has existed as the relation since ADR 0007 with
nothing that satisfies it by construction, so every narrowing was hand-built
and the relation had to be checked against it afterwards.

Catallaxy is where that cost showed. It wrote `MESH_NETWORK_SHARED` beside
`MESH_NETWORK` and `X509_ISSUANCE_SHARED` beside `X509_ISSUANCE`, then kept
a `crossable` table mapping each signature name to its narrowed form, and
the table checked `narrows` between them because nothing else did. One fact
in three places: the signature, the twin, and the join. A field added to the
full form did not reach the twin, and the twin's description drifted from
it.

## Considered options

**`exports` names the surviving fields**, so the boundary declares what
crosses and the signature is implied. Rejected because `exports` is a
reference — which unit a re-export comes from — and this would make it a
second place signatures are defined, reachable only through an inclusion. It
also cannot express the reading side: a requirer that wants the narrow view
writes it in `requires`, and under this option there would be nothing to
write.

**A per-field locality marking**, which is where this started as `T.local`:
every field says whether it may leave. Rejected before, and the reason
stands — it is a property of the signature's fields rather than of the
boundary, so it is true or false everywhere at once, and it could be true by
accident. A projection says what crosses _at the boundary that decided it_.

**A denylist**, `without signature [ "adminSecret" ]`. Rejected because a
field added to the signature later would begin to cross without anyone
saying so. An allowlist makes the default for a new field "stay where it
is", which is the default `exports` already takes.

## Consequences

`narrows` holds by construction wherever `project` built the narrowing, so
the relation keeps its job — checking hand-written narrowings and provider
compatibility — and stops being the only thing standing between a twin and
its original.

Nothing a distribution added to its own `mkSig` wrapper travels through a
projection, because core's argument pattern is closed and `project` calls it
with `name`, `canonicalName`, `description` and fields. For catallaxy's
`behaviour` — the runtime checks any provider of a signature owes — that is
the right answer rather than a gap: the obligation belongs to whoever runs
the thing and is discharged in that unit's own link, and a boundary
re-exporting a view of it runs nothing. Both of catallaxy's twins already
dropped it, one with `behaviour = [ ]` and a comment saying it "promises
less, including less behaviour", the other by omission.

A projection cannot refuse to cross at all, which the `crossable` table
could by leaving a signature out. That is ADR 0012.

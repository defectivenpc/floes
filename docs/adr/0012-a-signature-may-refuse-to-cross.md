# A signature may refuse to cross

`mkSig` takes `mayExport`, default true. A signature that sets it false
cannot be the signature of an inclusion's `exports`, and the linker refuses
it naming the signature and the inclusion.

Some signatures describe a thing that exists in exactly one place, so there
is no narrowing of them worth having. Catallaxy's `MESH_OPERATOR` names a
controller that reconciles CRs installed in one cluster; a peer handed it
would hold a reference to a controller that is not there, and every manifest
it renders from that reference applies cleanly. `MESH_ADMIN` is a Secret in
one namespace of one cluster. Projecting either produces something whose
remaining fields are still positions in a place the reader is not.

This was enforced by absence: catallaxy's `crossable` table listed what
could cross, and a signature not in it was refused. ADR 0011 deletes the
table, and with it the only thing that said no.

## Considered options

**Nothing.** The author chooses the export signature, and choosing a
local-only one is a mistake visible in the boundary's header. Rejected
because the whole argument for an authored boundary is that a reader can see
what crosses — and a reader who can see it is not the same as a check, which
is the distinction this repository keeps making about `T.deferred`,
`singleton` and `derivedFrom`. Each of those is a fact only the author
knows, declared once, enforced by the linker.

**A per-field marking**, `T.local` again. Rejected for the third time, and
for the reason ADR 0011 records: a locality marking asks every field about a
boundary most of them never meet. "There is nothing of this for a peer to
read" is a property of the signature as a whole, which is where it belongs.

## Consequences

One fact, in the file that defines the signature, instead of a membership
test against a table somewhere else. An author reading `MESH_OPERATOR` sees
why it stays put without finding the distribution's table first.

`mayExport` is checked where `exports` is resolved rather than at `mkSig`,
so a signature may still be `requires`, `provides` and `collects` of an
ordinary unit — refusing it everywhere would refuse the thing it is for.

It is a positive default, which means a distribution's signatures cross
unless an author says otherwise. The opposite default would be safer and is
wrong: most signatures are portable, and a default that made every author
opt in would be a second `crossable` table spread across the catalogue.

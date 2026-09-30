# Unexercised machinery that shapes vocabulary comes out

A review pass over the library found four type-ish words for three concepts,
and three surfaces with no caller anywhere. We deleted `link`'s `scope`,
`T.local`, `isUncrossable`, `requiresOptional` and `mkOutputKind`, and
renamed `as` and `fields` on the survivor. The rule applied: **code nobody
exercises is worse than code that does not exist, because it still costs
vocabulary.**

## What made each deletable

`mkOutputKind` was not a deletion so much as a discovery — sealing already
built a `T.record` out of a signature's fields, which is exactly what a
kind's schema was. Two constructors for one record, and the second one
forced every reader to work out how a "kind" differed from a "signature". It
didn't.

`requiresOptional` had no caller in `lib/`'s own tests or in either example,
and RFC 0001 records that it already replaced a `requiresMany` that was also
removed. Two designs, no users.

`scope` and `T.local` are the ones that cost something. `scope` is
catallaxy's lab→cluster nesting and `T.local` exists only so `scope` can
refuse fields that mean nothing in another link. Nothing in `examples/` used
either, and `T.local` was the reason `T` carried a locality concept that the
NixOS examples — the harder of the two domains — never needed once.

## Why that was the right call and not just tidying

The test that decided it: **could anyone point at a check that would have
caught these breaking?** For `scope`, the answer was six tests against
synthetic fixtures and no worked example, which is a check that the code
still runs rather than that it still works.

Renaming was the other half. `as` was a required argument that nothing read
— the bijection check it existed for lives in catallaxy — so it was ceremony
with a docstring claiming a guarantee the library did not provide. It is now
`canonicalName` and `link` enforces it, in the one direction that is
enforceable: a name may not mean two signatures. The reverse would forbid a
floe holding a primary and a replica on one signature.

## Consequences

Catallaxy's lab/cluster nesting breaks. That is the real cost and it falls
in the other repo. `docs/migrating.md` records the condition for `scope`
returning: a worked multi-link example, not a request — because the reason
it was deletable is that no test would have noticed it rotting.

Two additions came out of the same pass and are not covered here:
`T.derivedFrom` and `link`'s `defaults`. Both change resolution semantics
rather than trimming it, and both are argued where they are implemented.

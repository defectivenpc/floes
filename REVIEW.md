# Review: closed

Both items are answered. This file stays because the second one has a
mechanical change still outstanding.

**"Runtime still doesn't make sense to me. I get why, I don't understand
how. How is something reading the runtime value."** The word was wrong and
so was the design: `T.runtime`'s token carried a label and a constant, and
nothing could have filled the value in. A provider now declares a
**retrieval**, an ordinary signature saying where the value will be
readable, and `link.deferredSites` is the list a backend reads to find the
work. `tests/examples.nix` performs the substitution, which is the proof the
site list is enough. The word is now `deferred`, the programming-language
one. See [ADR 0005](docs/adr/0005-the-provider-declares-the-retrieval.md).

**"Shape is still the wrong word. We can borrow fields from the ML module
mixin vocab. Fields are on signatures."** Agreed, and `mkSig` takes
`fields`. It accepts either an attrset of `T`s or a bare `T`, dispatching on
whether the argument has a `tag`, and normalises an attrset to `T.record`,
so one word covers both a narrow interface and an opaque `T.attrsOf T.any`
output, which is what the `shape` rename was reaching for.

The residue is honest: `shape` survives as the internal attribute name in
`lib/`, because `T.record` stores its own `fields` and a signature storing
the author's argument under the same name makes `lib/link.nix` read
`sig.fields.fields`. It appears in no document and in nothing an author
writes. Two alternatives lost. Taking both names as mutually exclusive
arguments gives two spellings for one thing, which
[ADR 0003](docs/adr/0003-trim-unexercised-surface.md) deleted elsewhere.
Renaming `T.record`'s own field churns the type layer to fix an internal
name.

The rename touches 55 sites and lands after the core work in
[ADR 0007](docs/adr/0007-a-provider-must-answer-the-requirers-signature.md)
and [ADR 0008](docs/adr/0008-per-floe-eval-stays-cacheable.md), so that it
moves settled code.

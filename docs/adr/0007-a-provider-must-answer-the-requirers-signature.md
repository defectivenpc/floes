# A provider must answer the requirer's signature, checked from headers

Resolution keys on `sig.name`, a bare string, and nothing ever compared the
requirer's shape to the provider's. Two signatures sharing a name with
different shapes link cleanly:

```nix
SIG_PROVIDER = mkSig { name = "S"; shape = T.record { host = T.str; }; };
SIG_CONSUMER = mkSig { name = "S"; shape = T.record { host = T.str; port = T.port; }; };
```

The link succeeds. The consumer then dies with `attribute 'port' missing`,
naming no floe, no signature and no provider: Nix's error, several frames
from the cause, and not catchable by `builtins.tryEval`. That is RFC 0001's
open question 4 ("signature evolution… needed before third-party floes
exist") in its concrete form, and it is the error a third-party floe pinning
an older copy of a signature gets today.

`link` now checks, before anything evaluates, that the provider's shape is a
width-supertype of the requirer's.

## The rule

Provider-shape `<:` requirer-shape, with ordinary covariance:

| Shape                  | Compatible when                                               |
| ---------------------- | ------------------------------------------------------------- |
| `record`               | every requirer field present and compatible (width and depth) |
| `listOf` / `attrsOf`   | the inner shapes are compatible                               |
| `enum` / `taggedUnion` | the provider's values/variants are a **subset**               |
| `nullOr`               | a non-null provider satisfies a `nullOr` requirer             |
| `derivedFrom`          | transparent; `checkValue` already recurses to inner           |
| `any`                  | top: satisfies any requirer, satisfied only by `any`          |
| `deferred`             | asymmetric; see below                                         |

`T.deferred` is the one asymmetry and it is the valuable one. A concrete
provider satisfies a requirer that declared the field deferred, because the
requirer already handles both. A deferred provider against a concrete
requirer is **refused at link**, which moves an error that used to surface
when the value was read into the header check, where it can name both sides:

```
floe link error: 'postgres' provides 'DATABASE' but cannot answer the
signature 'webapp' requires as hole 'database'.
  - DATABASE.superuserPassword: provider offers `deferred string`, requirer
    declared `string`. A value that does not exist until after apply cannot
    satisfy a field read at evaluation time.
Either widen the requirer's field to `T.deferred T.str`, or read the
concrete field beside it.
```

## Why not identity by value, and why no version numbers

Refusing two distinct `mkSig` values that share a name was the obvious
alternative and is too strict: it forbids the case compatibility handles,
where a third-party floe pins an older copy of a signature that is still
structurally satisfied. The width rule accepts that and rejects the real
mismatch.

It is also why there is no `version` field. The compatibility rule _is_ the
evolution rule: adding a field to a signature is compatible with every
existing requirer, removing or retyping one is not, and the error says which
field. A version number would restate that with less precision and would
need a compatibility rule of its own to mean anything.

## Why emitted signatures are not checked

An emitted signature has no requirer. Nothing `requires` an `out` kind,
since the adapter reads `result.out.<name>`, so there are not two sides to
compare, and co-emitters of one name must be free to differ. The NixOS
example depends on that: `postgres` emits `systemd` and `users` under
`nixos.config` while `networking` emits `networking`, and
`examples/README.md` argues that the schema has no reason to be shared and
here must not be.

Compatibility is a requirer↔provider relation. With no requirer there is no
check, by design.

## Consequences

Third-party floes become possible, which they were not: the failure above is
the one a stranger's floe hits first, and it was unattributable. A
distribution can now also widen a shared signature without coordinating a
release, since widening is the compatible direction.

The check is header-only, so it costs nothing per value and runs before any
body evaluates, the same property that makes `derivedFrom`'s refusal and the
singleton check reportable rather than discovered.

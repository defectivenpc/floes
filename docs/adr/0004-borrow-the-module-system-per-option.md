# Input validation borrows the module system per option, not per floe

A floe's `inputs` are declared with NixOS option types, so validating what a
deployer passed means asking the module system. `checkInputs` did that with
a whole `lib.evalModules` per floe — which is the module system's
_whole-tree_ entry point, used to check one attrset. It now calls
`lib.modules.mergeDefinitions` per option: the same machinery at the
granularity the job actually has. 6 MB against 107 MB for a thousand floes
of fifteen inputs, with identical semantics.

## What the measurements ruled out

The question that prompted this was whether borrowing nixpkgs' type library
was itself the overhead, and whether floe should stop doing it. It is not:

| 100k scalar checks     | cpu     | allocated |
| ---------------------- | ------- | --------- |
| `lib.types.port.check` | 0.060 s | 11 MB     |
| `T.checkValue T.port`  | 0.114 s | 23 MB     |

`lib.types` is **twice as cheap** as floe's own `T`, because `check` is a
direct function call where `checkValue` chains `if ty.tag == …` comparisons
first. And a three-way test of validation strategies put
mkOption-plus-direct-walk and T-plus-checkValue at **1 MB each, identical**
— so switching type languages buys exactly nothing, while costing
`types.package`, `types.path`, `types.submodule`, and the `mkOption` fields
`renderInputs` turns into generated docs.

The cost was never the types. It was `evalModules`.

## Rejected alternatives

**One type language, `T` everywhere.** Zero measurable gain, and it would
mean re-implementing a chunk of `lib.types` to reach parity. Two languages
stay, and `docs/floe-api.md` says why: `T` exists for what it can express —
`T.deferred`, `T.derivedFrom`, sealing that drops rather than errors — not
because it is faster. It is not.

**Collapse `inputs` into `requires`, with the deployer as a provider.** One
mechanism instead of two, and one type language falls out of it. Rejected on
ergonomics: `instantiate { port = 5432; }` at a call site is much better
than declaring a config-provider floe per instance, and `mkOption` is where
the generated input documentation comes from. This is the alternative peak,
and it is lower.

**A hand-rolled walk over the declared options.** Tried first, and it is
where the reasoning went wrong. It reached 5 MB against `mergeDefinitions`'
6 MB — no real gain — while silently dropping a submodule's nested defaults,
rejecting `mkIf` in a supplied value, and needing a second code path that
fell back to `evalModules` when any input's type had `getSubModules`.
Thirty-five lines of ours that could be wrong, to save nothing. The prompt
that killed it: _"is the only way to type check to fill in default values?
That doesn't seem like a good design."_ Correct — that conflation was an
artifact of using `evalModules`, which can only produce a whole config tree.
`mergeDefinitions` separates checking from default-filling because
`type.merge` does the latter.

## Consequences

**Validation is lazy per input, where it used to be eager.** A declared
input whose supplied value is badly typed, and which the body never reads,
no longer fails. That matches NixOS, which was measured rather than assumed:
a badly-typed `networking.hostName = 12345` sits in a real system evaluation
and never errors unless something reads it. Floe was stricter than the
system it is modelled on, and a floe author's mental model should be the one
they already have.

The _shape_ of an instantiate call stays eager — undeclared keys and missing
requireds are wrong whether or not anything reads them, and neither check
forces a value. The missing-required message is floe's own rather than the
module system's, because "the option was accessed but has no value defined.
Try setting the option" is option-tree language for what is a function call.

**`mergeDefinitions` is exported from `lib.modules` under a blanket note
that not everything in that list is a public interface.** The risk is
accepted: the alternative is maintaining a worse copy, and four tests in
`tests/default.nix` pin the behaviours relied on — submodule defaults,
property wrappers, refusal on a bad type, eager shape checks — so a nixpkgs
bump that moves them fails the suite rather than someone's deploy.

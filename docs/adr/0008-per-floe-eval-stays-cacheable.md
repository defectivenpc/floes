# Per-floe eval stays cacheable, which decides two unrelated-looking things

> **Status: the premise is closed; both decisions stand.** This existed to
> keep per-floe caching _possible_, on the belief that a floe is a natural
> memoization unit and that eval time is the complaint NixOS gets.
> Measurement then killed both halves:
>
> |                                                     |                                                           |
> | --------------------------------------------------- | --------------------------------------------------------- |
> | the fleet's cache partition                         | **4 units of 29**; one component of 26                    |
> | twenty-nine floes, against a whole NixOS evaluation | **36 MB and 3% of the time**                              |
> | catallaxy's `homelab.local` lab plan                | 0.58 s / 171 MB, of which linking is single-digit percent |
>
> So caching cannot be done per floe, because the components are the link,
> and there is almost nothing to win if it could, because the 2.1 s is
> nixpkgs and the module system. A perfect floe cache saves 74 ms of a 2.2 s
> evaluation. **Not worth building**, and recorded here as decided rather
> than pending so the next reader does not spend a month re-deriving it. The
> `lib.fix` knot can stay; there was nothing behind it.
>
> Both decisions below stand, each on a reason independent of caching, which
> is why this is a status note rather than a withdrawal:
>
> - **Cycles are derived, not declared.** That answers RFC 0001's open
>   question 3 on its own, gives `link.cycles`, which is what produced the
>   measurement above, and makes the stratification check possible. A
>   distribution refusing cycles gets it as a policy.
> - **Packages are inputs; a package set is not.** A package set can be
>   neither hashed _nor serialised into the IR_, and which nixpkgs and which
>   overlays are the deployer's choice regardless. The caching argument was
>   one reason among several, and the weakest of them.
>
> `link.cycles` is what remains useful about the caching question: if a link
> ever has small components and linking dominates, it will say so.

The argument, as it stood when this was written: eval time is the complaint
NixOS gets, and a floe's output depends only on its declared inputs and
resolved requires, which makes it a natural memoization unit. Nothing
implemented it, because the single `lib.fix` in `lib/link.nix` stands in the
way, so this recorded the decision to stop _foreclosing_ it, on the grounds
that two choices which look unrelated both decide whether it stays possible,
and both would be expensive to revisit once there are floes in the wild.

That reasoning was sound and its premise was wrong. See the status note.

## Cycles are derived

RFC 0001's open question 3 asked whether eval-time cycles between floes are
discouraged-by-convention or rejected-by-linker. Neither. They are derived.

`link` computes `wiringOne` and `wiringAll` from headers before any body
evaluates, so the eval graph and its strongly-connected components are known
without running anything. The linker exposes them as `link.cycles`, and
every unit absent from all of them is its own cache unit. Nothing has to
declare them, because a declaration would be ceremony for a fact the linker
already has, and a wrong declaration would be a new error class.

### What exposing them showed

This section first claimed that a component is "usually one unit". Building
`link.cycles` measured it, and that is false of the worked example by a wide
margin. `examples/nixos`:

| link  | units | components | cache units |
| ----- | ----- | ---------- | ----------- |
| small | 5     | one of 5   | 1           |
| fleet | 29    | one of 26  | 4           |

So per-floe caching, on the design this library is for, would buy almost
nothing as the example is structured. "A floe is a natural memoization unit"
is true of a floe in isolation and false of a floe in a link with an owned
namespace.

The cause is structural, and it is `docs/adr/0001`'s own design rather than
an accident: a namespace with an owner means one floe collecting from every
peer, and those peers reaching the owner back through whatever routes them.
That is a cycle through almost everything.

The dissolution is visible in the same place. **An eval edge is per hole;
the dependency it stands for is per field.** `nginx` reads `NETWORK.domain`,
which does not depend on the port collection: `openPorts` is the field that
does, and `T.derivedFrom` already marks it. The graph is coarser than the
truth, and a field-granularity graph is where a real answer would have to
start. Nothing here does that, so the honest statement of this ADR's caching
half is: the _preconditions_ are settled, and the gain is now measured and
looks small.

Rejecting cycles outright was the alternative. The NixOS example depends on
two mutual ones (nginx needs the domain while `networking` needs nginx's
ports, nginx needs `webapp`'s route while `webapp` needs nginx's base
domain) and `examples/README.md` argues they are the half of NixOS's
recursion problem floe does solve, since a cycle's blast radius is one link
and a legal cycle stays legal. Refusing them would trade a working property
for a caching convenience.

A distribution that wants acyclic eval gets it as a **policy** over
`link.cycles`, in one line, which is where domain legality already lives.

This also pays off before any caching exists. A component is known
pre-evaluation, so a structural read inside one could be refused up front,
the stratification check RFC 0001 describes. An earlier draft pointed at
`examples/nixos/broken.nix`'s `interpolating` case as the example; that one
has been catchable since a deferred token learned to refuse interpolation,
so the general motivation is what remains rather than that case.

## Packages are inputs; a package set is not

A cache key is a hash of a floe's inputs plus its resolved requires.
Resolved requires are sealed pure data and hash fine. Inputs are native
NixOS option types, which is correct for every other reason, and it means
that if `pkgs` is an input, the key contains an attrset of a hundred
thousand thunks and functions, which cannot be hashed and must not be
forced.

So a floe takes the packages it needs, one at a time:

```nix
inputs.postgresql = lib.mkOption { type = lib.types.package; };
```

A derivation hashes as its `drvPath`, and serialises into the IR as its
`outPath` with no help: `builtins.toJSON` on a derivation yields the store
path string. A package set is neither hashable nor serialisable, so it
cannot be an input to anything that wants to be cached or handed to a
backend.

The rejected alternative was a `PACKAGES` signature providing blessed
packages, which reintroduces a provider that every floe requires and makes
the package set cross a boundary where `T.attrsOf T.any` would meet it.

## Consequences

The deployer pays. A deployer writes `pkgs.postgresql` per floe that needs
it, and `defaults` cannot help because packages are inputs rather than
signatures. For a fleet of twenty-nine units that is real ceremony, and it
is the cost of leaving caching possible. Both examples dodge the question
with `package = "/run/current-system/sw"` as a string, which is neither of
these answers and is why the question had to be asked.

How caching works is not decided here. The `lib.fix` knot is still the
obstacle it was: a floe's inputs are thunks in a global knot rather than
values, and resolving that is its own design. The two decisions above are
the ones that had to be made before there are floes in the wild, because
both would be breaking changes afterwards.

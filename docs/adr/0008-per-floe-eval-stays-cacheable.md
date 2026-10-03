# Per-floe eval stays cacheable, which decides two unrelated-looking things

Eval time is the complaint NixOS actually gets, and a floe's output depends
only on its declared inputs and resolved requires, which makes it a natural
memoization unit — `examples/README.md` calls that floe's strongest answer
to the complaint, and records that nothing implements it because the single
`lib.fix` in `lib/link.nix` stands in the way.

Nothing here implements it either. What this records is the decision to stop
foreclosing it, because two choices that look unrelated both decide whether
it stays possible, and both are expensive to revisit once there are floes in
the wild.

## Cycles are derived, and the cycle is the cache unit

RFC 0001's open question 3 asked whether eval-time cycles between floes are
discouraged-by-convention or rejected-by-linker. Neither. They are derived.

`wiringOne` and `wiringAll` are computed from headers before any body
evaluates, so the eval graph and its strongly-connected components are known
without running anything. The linker exposes them as `link.cycles`, and
every unit absent from all of them is its own cache unit. No declaration is
required, because a declaration would be ceremony for a fact the linker
already has, and a wrong declaration would be a new error class.

### What exposing them immediately showed

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

What would dissolve it is visible in the same place. **An eval edge is per
hole; the dependency it stands for is per field.** `nginx` reads
`NETWORK.domain`, which does not depend on the port collection at all —
`openPorts` is the field that does, and `T.derivedFrom` already marks
exactly it. The graph is coarser than the truth, and a field-granularity
graph is where a real answer would have to start. Nothing here does that, so
the honest statement of this ADR's caching half is: the _preconditions_ are
settled, and the gain is now measured and looks small.

Rejecting cycles outright was the alternative. The NixOS example depends on
two mutual ones — nginx needs the domain while `networking` needs nginx's
ports, nginx needs `webapp`'s route while `webapp` needs nginx's base domain
— and `examples/README.md` argues they are the half of NixOS's recursion
problem floe does solve, since a cycle's blast radius is one link and a
legal cycle stays legal. Refusing them would trade a working property for a
caching convenience.

A distribution that wants acyclic eval gets it as a **policy** over
`link.cycles`, in one line, which is where domain legality already lives.

This also pays off before any caching exists. A component is known
pre-evaluation, so a structural read inside one could be refused up front —
the stratification check RFC 0001 describes. An earlier draft pointed at
`examples/nixos/broken.nix`'s `interpolating` case as the example; that one
has been catchable since a deferred token learned to refuse interpolation,
so what remains is the general motivation rather than that case.

## Packages are inputs; a package set is not

A cache key is a hash of a floe's inputs plus its resolved requires.
Resolved requires are sealed pure data and hash fine. Inputs are native
NixOS option types, which is correct for every other reason — and it means
that if `pkgs` is an input, the key contains an attrset of a hundred
thousand thunks and functions, which cannot be hashed and must not be
forced.

So a floe takes the packages it needs, one at a time:

```nix
inputs.postgresql = lib.mkOption { type = lib.types.package; };
```

A derivation hashes as its `drvPath`, and serialises into the IR as its
`outPath` with no help — `builtins.toJSON` on a derivation yields the store
path string. A package set is neither hashable nor serialisable, so it
cannot be an input to anything that wants to be cached or handed to a
backend.

The rejected alternative was a `PACKAGES` signature providing blessed
packages, which reintroduces a provider that every floe requires and makes
the package set cross a boundary where `T.attrsOf T.any` would meet it.

## Consequences

The deployer pays. `pkgs.postgresql` is written per floe that needs it, and
`defaults` cannot help because packages are inputs rather than signatures —
for a fleet of twenty-nine units that is real ceremony, and it is the cost
of leaving caching possible. Both examples currently dodge the question
entirely with `package = "/run/current-system/sw"` as a string, which is
neither of these answers and is why the question had to be asked.

What is explicitly not decided here is how caching works. The `lib.fix` knot
is still the obstacle it was: a floe's inputs are thunks in a global knot
rather than values, and resolving that is its own design. The two decisions
above are the ones that had to be made before there are floes in the wild,
because both would be breaking changes afterwards.

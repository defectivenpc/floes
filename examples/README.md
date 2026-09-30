# Three worked examples

None is for reuse. Catallaxy has its own Kubernetes distribution and nixpkgs
has its own module system; these exist so floe is developed against more
than one domain, and so a reader can see the library in use without adopting
anything.

- **[`nixos/`](nixos)** — the probe. Fine-grained units, a namespace with an
  owner, services contributing to it, two Postgres servers on one host. Two
  links from one set of floes: a five-unit one to read, a twenty-nine-unit
  one to measure.
  [ADR 0001](../docs/adr/0001-the-nixos-examples-give-namespaces-an-owner.md).
- **[`k8s/`](k8s)** — the contrast, in one file. Coarse units, a resolution
  chain, loose output. The shape floe was originally designed against.
- **[`wrapped/`](wrapped)** — a spike that answers "could floes just wrap
  nixpkgs modules?". They can, at about 200× the cost.
  [ADR 0002](../docs/adr/0002-wrapping-nixpkgs-modules-is-not-the-path.md).

```bash
nix flake check          # both links, each also evaluated as a real NixOS system
./examples/refuse.sh     # the two failures no Nix test can hold
./bench/run.sh           # per-floe cost, at two weights
```

## What the NixOS example establishes

NixOS modules scale badly because one global option tree has no owners.
Nothing declares what a component needs or promises, so
`networking.firewall.allowedTCPPorts` is written by a dozen modules that
have never heard of each other, and two services claiming one port is not an
event — the lists concatenate and whichever process binds first wins at
runtime.

**A service can contribute to a namespace it does not own.**
`networking.nix` is the only floe in either link that emits `networking`;
nginx, the databases and `metrics` provide `PORT_CLAIM`s that it collects
and merges under a policy of its own. Nobody wrote a firewall rule.

**Not every namespace needs an owner, and that matters for ergonomics.** A
test pins the distinction: `networking` has exactly one emitter because a
_port list_ merges by policy. `systemd` and `users` have several, and that
is fine — an attrset keyed by a unique name is disjoint by construction, so
many writers cannot collide. The rule is "namespaces whose merge carries
policy need an owner", not "everything needs an owner".

**Two instances of one service, which stock NixOS cannot express with its
own module at all.** `services.postgresql` is a singleton path, so
[`postgres.nix`](nixos/postgres.nix) does not use it: it emits
`systemd.services.postgres-<unit>`, its own user, group and data directory,
every one keyed by the link's name for the instance. Two coexist; the fleet
runs three.

**Mutual dependencies between floes work.** Two of them in the small link:
nginx needs the domain while `networking` needs nginx's ports, and nginx
needs `webapp`'s route while `webapp` needs nginx's base domain. Laziness
resolves both. This is the half of NixOS's recursion problem floe does solve
— a cycle's blast radius is one link, and a legal cycle stays legal.

**Sealing has teeth.** `postgres` knows its data directory and does not
promise it, so nothing can read it. In stock NixOS that read is one
attribute away and nobody declared it.

**Four collisions are refused, each by whoever owns the namespace.** Two
providers of one signature; two instances claiming one port; two workloads
claiming one hostname; two instances of a floe that writes fixed paths. The
last is the only one nothing downstream could have caught — both fragments
are _identical_, so every merge accepts them and the deployer silently gets
one of the thing. That is what `singleton` is for.

**The fragments are real NixOS config.** Both links are evaluated by
`nixosSystem` and forced to the toplevel derivation path. A snapshot cannot
tell a real option path from a plausible one; this can.

## Performance

Per-floe marginal cost, hand-written floes, linear to n=2000:

|                                           | per floe    | 1000 floes       |
| ----------------------------------------- | ----------- | ---------------- |
| trivial body (one option, one string)     | 0.13 ms     | 0.154 s / 133 MB |
| realistic body (`bench/run.sh` weight 15) | **0.34 ms** | 0.358 s / 323 MB |

A stock minimal NixOS evaluation is **1.63 s and 614 MB**, so a thousand
realistic floes cost about a fifth of its time and half its memory. The
twenty-nine-floe fleet — 90 graph edges, two twenty-member collections —
links in 27 ms, and evaluating it as a full NixOS system adds **39 MB and no
measurable time** over the stock baseline.

Floes are cheap. What is not cheap is wrapping nixpkgs modules, at ~77 ms
and ~26 MB each; see [`wrapped/`](wrapped).

## Ergonomics

Measured rather than asserted, and the numbers are pinned by a test:

|                                                    | units | deployer lines | `.bind` calls |
| -------------------------------------------------- | ----- | -------------- | ------------- |
| [`nixos/system-small.nix`](nixos/system-small.nix) | 5     | 11             | 1             |
| [`nixos/system-fleet.nix`](nixos/system-fleet.nix) | 29    | 39             | 23            |

The small link is roughly the size of its stock NixOS equivalent — twelve
lines against eleven — so brevity is not the claim. What is absent is:

|                    | floe                       | stock NixOS     |
| ------------------ | -------------------------- | --------------- |
| firewall ports     | derived from claims        | written by hand |
| virtual hosts      | derived from claims        | written by hand |
| scrape targets     | derived from claims        | written by hand |
| workload hostnames | default to the unit's name | written by hand |
| ordering           | derived from signatures    | `after = [ … ]` |

So moving a workload to another port is one number in one place and the
proxy target follows — `testOneEditPropagates` asserts that, including that
it must _not_ open a port, since the workload sits behind the proxy.

**The ceremony is real and it is the bind count.** Three databases answer
`DATABASE`, so all twenty-three consumers must say which they mean. That is
79% of the fleet's units carrying an explicit `.bind`. The honest read: a
stock NixOS deployer writes a connection string per app anyway, so this is a
different spelling of work they already did — but it is exactly the cost
that a canonical default-provider rule would remove, at the price of the
exactly-one property. The number is here so that trade can be argued with
evidence.

**And the author pays.** About 350 meaningful lines for seven floes and six
signatures, plus `postgres.nix` being the nixpkgs module's job done again.
In stock NixOS that is nixpkgs' work and the deployer pays none of it. Floe
moves cost from deployer to author, which trades well only where components
are written once and deployed many times.

## What it does not establish

**The other half of the recursion problem is untouched.**
[`nixos/broken.nix`](nixos/broken.nix) has a floe that reads the merge it
contributes to. It recurses, and Nix says `infinite recursion encountered`
naming no floe, no hole and no field. Note what decides it: nginx requires
the _same hole from the same floe in the same cycle_ and is fine, because it
reads `domain` rather than `openPorts`. The **field** is what makes it
fatal, so a polarity annotation would have to be per field, not per hole.

Worse, and found while writing the tests: `builtins.tryEval` catches only
`throw` and `assert`, so whether a failure is testable tracks _who reported
it_. floe's own errors are catchable; Nix's `cannot coerce` and
`infinite recursion` are not. No test can hold them and no library code can
wrap them in a better message, because nothing runs after them. A readable
error for a structural read in a cycle has to come from rejecting the cycle
_before_ any body evaluates — which is what RFC 0001's stratification check
would do, and why it is not cosmetic.

**There is no real escape hatch.** A deployer needing a flag no floe exposes
can fork the floe, or patch the fragment on its way out — which works today
with no library support, because the adapter is their own function.
`default.nix` shows it and spells out the cost: the patch names an option
path inside a floe's output, so it depends on internals the floe never
promised. Sealing protects `provides`, not `out`. And it cannot change
anything another floe already read through a signature, so it will never be
as powerful as `mkForce` on a shared tree.

**Merge lawfulness is not addressed and cannot be.** Inside a floe the
module system's ad hoc merges are exactly as they were. Floe encapsulates
that problem; it does not solve it.

**Incrementality is not built.** A floe's output depends only on its
declared inputs and requires, which makes it a natural memoization unit —
floe's strongest answer to the complaint people actually have about NixOS
eval time. Nothing here does it, and the single `lib.fix` in `lib/link.nix`
stands in the way, because a floe's inputs are thunks in a global knot
rather than values.

## The contrast with `k8s/`

|               | nixos             | k8s           |
| ------------- | ----------------- | ------------- |
| unit          | a systemd service | a Helm chart  |
| floes         | 7                 | 3             |
| signatures    | 6                 | 2             |
| collected     | 3                 | 0             |
| eval cycles   | 2, both mutual    | 0, a chain    |
| output typing | narrow, per floe  | loose, shared |

Kubernetes components have coarse grain and clean boundaries, so nothing
needs a collection and nothing points backwards. A rendered manifest is
opaque by nature, so there is no useful `T.record` to write for it — and
floe does not insist on one. Both use `mkSig`, `requires`, `collects` and
`mkOutputKind` unmodified. Floe was designed against the right-hand column;
the left is the harder case, and the reason a second domain was worth
testing against.

## A note on output schemas

An output kind is a dotted name plus a schema. The name is what collects
fragments into one bucket; the schema has no reason to be shared, and in the
NixOS example it must not be — `postgres` emits `systemd` and `users`,
`networking` emits `networking`, and they have nothing in common.

So each floe narrows the schema itself, the way a NixOS module declares its
own options. [`nixos/kinds.nix`](nixos/kinds.nix) is the whole of it. This
needed no library change: `lib/link.nix` already checks each floe's `out`
against that floe's own kind and groups by `kind.name`. It had just never
been written down.

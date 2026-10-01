# Three worked examples

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
./examples/refuse.sh     # the one failure no Nix test can hold
./examples/shell-check.sh # what the emitted shell actually does
./bench/run.sh           # per-floe cost, by body weight and body form
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

**A value that does not exist yet is refused at eval — and the loop
closes.** Postgres's password is `T.deferred`: put it where NixOS config
wants a string and the linker says so, naming the floe it came from, instead
of NixOS reporting an attrset where it wanted text some frames later.

That is half of it. The _provider_ also declares a **retrieval** — an
ordinary signature saying where the value will be readable once it exists —
so something can eventually fill it in. Postgres declares `nixos.fileRef`;
cert-manager in the k8s example declares `k8s.secretRef`. The same
`T.deferred T.str` on both sides, two mechanisms with nothing in common,
which works only because the provider declares the retrieval and not the
signature's field.

Core never learns what a Secret is. It exposes `link.deferredSites` — one
entry per token that reached output, saying what to read and where to write
it — and ships no substitution function, because a ConfigMap, a Secret, an
annotation, a file and an HTTP lookup are five mechanisms for one job.
`testABackendCanCloseTheLoop` does the substitution in a test, which is the
proof the site list is enough to write a real backend against.

**A collection provisioning per-consumer secrets, which is this example's
own thing.** Postgres cannot know its consumers at author time, so it
`collects` a `DB_ROLE_CLAIM` and provisions one role, one database and one
credential per claimant. Two hooks, because the prerequisites differ: the
credentials before the server starts, so a consumer's unit can mount them;
the roles after, because a role cannot be created before the server accepts
connections. Neither the role name nor the database name is written by a
deployer — both are the claimant's own unit name.

In the fleet that is 20 workloads × 3 databases, and the credential a
workload mounts is its own: `dbpw:/var/lib/postgres-main/credentials/app1`,
not a secret shared by 23 consumers. `backup` meanwhile claims _no_ role and
takes the superuser credential, because it dumps the whole server — the
other half of the fan-in story, that not every consumer of a signature
contributes to its collection.

**Where a per-consumer value cannot go, and why.** A provide is one value
for every consumer, so a per-claimant _secret_ would have to be a map keyed
by unit — and that map is derived from the claim collection, so a claimant
reading it is a cycle through the fold. `T.derivedFrom` would refuse it,
correctly. A directory plus the consumer's own name is what is left. There
is a second, sharper reason: `mkDeferred` binds `source` to the unit whose
body calls it, so only a provider can mint a token for its own value — a
consumer cannot construct one pointing at its provider, which is right,
since provenance would otherwise be a claim the claimant makes about someone
else.

So the deferred half lands on the _superuser_ password, which is genuinely
one per instance. `superuserPasswordFile` for a consumer that passes it to a
process; the deferred value for one that must render it where a credential
cannot reach, with the retrieval saying where a backend would read it.

Worth noticing that the NixOS link has **zero** deferred sites even so,
because nothing there renders a secret into config — and putting the value
itself in config is exactly what [`nixos/broken.nix`](nixos/broken.nix)
demonstrates as a mistake. So the two examples show both halves: Kubernetes
renders a value into a manifest and needs a backend; NixOS hands over a path
and needs a **provisioning step**, which is a real cost rather than a free
lunch. In production that step is sops-nix, agenix or `systemd-creds`
instead of this one's `head -c 32 /dev/urandom`.
[ADR 0005](../docs/adr/0005-the-provider-declares-the-retrieval.md).

**And one bug class no Nix check can see.** `postgres.nix` emits its
provisioning as shell _strings_, which is forced: a floe's output must be
inert data, so it cannot build a script derivation. Every check here passes
on a string that parses as some shell, and `nixosSystem` accepts any string
at all. The first version of this SQL was syntactically valid and
semantically wrong —

```
CREATE ROLE webapp LOGIN PASSWORD SECRET      # no quotes; invalid SQL
```

— because the outer `sh -c '…'` had consumed the quotes.
`./examples/shell-check.sh` runs the emitted command with fake binaries on
`PATH` and asserts what `psql` actually receives. It is the only check in
the repo that would have caught it, and re-introducing the bug makes it
fail.

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

Per-floe marginal cost at n=1000, three inputs each, `bench/run.sh`:

|                       | `modules`        | `body`          |
| --------------------- | ---------------- | --------------- |
| trivial output        | 0.16 ms / 89 MB  | 0.06 ms / 22 MB |
| realistic output (15) | 0.32 ms / 150 MB | 0.19 ms / 58 MB |

Linear in the number of floes: 6, 23, 58, 116 MB at n = 100, 400,
1000, 2000.

`body` — a plain function — is about half the cost of `modules`, which runs
the floe's module list in its own `evalModules`. That is what `modules`
buys: the module system's merge inside a floe, and the ability to host an
existing NixOS module. Worth paying where it is wanted, which is why
`networking` and `nginx` keep it.

Neither form avoids `checkInputs`, which validates what the deployer passed.
Isolated:

| inputs declared | allocated per 1000 floes |
| --------------- | ------------------------ |
| 0               | 50 MB                    |
| 3               | 58 MB                    |
| 15              | 88 MB                    |

About **2.5 MB per declared input per thousand floes**, which is what makes
a large input space affordable. It used to be 5.5 MB and the whole call used
to cost twice as much, because `checkInputs` ran a whole `lib.evalModules`
per floe — the module system's _whole-tree_ entry point — to validate one
attrset. It now calls `lib.modules.mergeDefinitions` per option, which is
the same machinery at the granularity the job actually has. See
[ADR 0004](../docs/adr/0004-borrow-the-module-system-per-option.md).

Against a whole NixOS evaluation, forced to the toplevel derivation path:

|                       | cpu     | allocated |
| --------------------- | ------- | --------- |
| stock NixOS, no floes | 2.142 s | 614 MB    |
| small link, 5 floes   | 2.193 s | 630 MB    |
| fleet, 29 floes       | 2.216 s | 650 MB    |

**Twenty-nine floes cost 36 MB and about 3% of the time.** The fleet's own
link — 90 graph edges, two twenty-member collections — is 37 ms and 1 MB.

Floes are cheap. What is not cheap is wrapping nixpkgs modules, at ~77 ms
and ~26 MB each; see [`wrapped/`](wrapped).

## Ergonomics

Measured rather than asserted, and the numbers are pinned by a test:

|                                                    | units | deployer lines | `.bind` calls |
| -------------------------------------------------- | ----- | -------------- | ------------- |
| [`nixos/system-small.nix`](nixos/system-small.nix) | 5     | 11             | 1             |
| [`nixos/system-fleet.nix`](nixos/system-fleet.nix) | 29    | 37             | 15            |

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

**The ceremony was the bind count, and `defaults` is most of the answer.**
Three databases answer `DATABASE`. Before, every one of the twenty-three
consumers had to say which it meant — and worse, _adding_ the second
database broke all of them at once. `link { defaults.DATABASE = "main"; }`
is one line that keeps every consumer with no opinion working, and it took
the fleet to fifteen binds against a deliberately adversarial round-robin
across all three. A fleet with one dominant database would keep almost none.

What remains is irreducible: fifteen consumers that genuinely do want a
specific database, and a deployer has to say so somewhere.
`testTheDefaultDoesNotCollapseConsumers` pins that the default did not
quietly merge them — each backup still dumps a different one.

**And the author pays.** About 350 meaningful lines for seven floes and six
signatures, plus `postgres.nix` being the nixpkgs module's job done again.
In stock NixOS that is nixpkgs' work and the deployer pays none of it. Floe
moves cost from deployer to author, which trades well only where components
are written once and deployed many times.

## What it does not establish

**The recursion problem is now solved in the one place it was solvable.**
`NETWORK.openPorts` is `T.derivedFrom PORT_CLAIM`, so `link` refuses that
field to any peer contributing a claim — before anything evaluates, since
both facts are in the headers. What used to be
`infinite recursion encountered`, naming nothing, is an error naming both
floes, the collection and the field.

Note what still works, and why it had to be per field: nginx requires the
_same hole from the same floe in the same cycle_ and is fine, because it
reads `domain`.

That also made the failure **testable**, which it had not been:
`builtins.tryEval` catches only `throw` and `assert`, so whether a failure
can be tested tracks _who reported it_. Rejecting the bad read up front
moved it from Nix's report to floe's. One case remains on the wrong side of
that line — [`nixos/broken.nix`](nixos/broken.nix)'s `interpolating`, where
a deferred token is coerced by string interpolation before anything typed
sees it, which is RFC 0001's open question 1. No test can hold it and no
library code can wrap them in a better message, because nothing runs after
them. A readable error for a structural read in a cycle has to come from
rejecting the cycle _before_ any body evaluates — which is what RFC 0001's
stratification check would do, and why it is not cosmetic.

**There is still no real escape hatch.** A deployer needing a flag no floe
exposes can fork the floe, or patch the fragment on its way out — which
works today with no library support, because the adapter is their own
function. `default.nix` shows it and spells out the cost: the patch names an
option path inside a floe's output, so it depends on internals the floe
never promised. Sealing protects `provides`, not `out`. And it cannot change
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

|               | nixos                 | k8s           |
| ------------- | --------------------- | ------------- |
| unit          | a systemd service     | a Helm chart  |
| floes         | 7                     | 3             |
| signatures    | 6                     | 2             |
| collected     | 3                     | 0             |
| body form     | 5 `body`, 2 `modules` | 3 `body`      |
| eval cycles   | 2, both mutual        | 0, a chain    |
| output typing | narrow, per floe      | loose, shared |

Kubernetes components have coarse grain and clean boundaries, so nothing
needs a collection and nothing points backwards. A rendered manifest is
opaque by nature, so there is no useful `T.record` to write for it — and
floe does not insist on one. Both use `mkSig`, `requires`, `collects` and
`out` unmodified. `networking` and `nginx` stay on `modules` so that path
stays load-bearing rather than being exercised only by fixtures. Floe was
designed against the right-hand column; the left is the harder case, and the
reason a second domain was worth testing against.

## A note on output schemas

An output kind is a dotted name plus a schema. The name is what collects
fragments into one bucket; the schema has no reason to be shared, and in the
NixOS example it must not be — `postgres` emits `systemd` and `users`,
`networking` emits `networking`, and they have nothing in common.

So each floe narrows the schema itself, the way a NixOS module declares its
own options. [`nixos/kinds.nix`](nixos/kinds.nix) is the whole of it. This
needed no library change: `lib/link.nix` already checked each floe's `out`
against that floe's own signature and grouped by its `name`. It had just
never been written down — and once it was, the separate `mkOutputKind`
constructor turned out to have been a second spelling of `mkSig` all along.

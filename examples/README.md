# Two worked examples

Neither is for reuse. Catallaxy has its own Kubernetes distribution and
nixpkgs has its own module system; these exist so floe is developed against
two domains instead of one, and so a reader can see the library in use
without adopting anything.

- **[`nixos/`](nixos)** — the probe. Fine-grained units, a namespace with an
  owner, services contributing to it.
  [ADR 0001](../docs/adr/0001-the-nixos-examples-target-the-substrate.md)
  says why this shape and not the easier one.
- **[`k8s/`](k8s)** — the contrast, in one file. Coarse units, a resolution
  chain, loose output. The shape floe was originally designed against.

```bash
nix flake check          # both, plus the NixOS example through a real nixosSystem
./examples/refuse.sh     # the two failures no Nix test can hold
```

## What the NixOS example is testing

NixOS modules scale badly because there is one global option tree and any
module may write any part of it. Nothing declares what a component needs or
promises, so `networking.firewall.allowedTCPPorts` is written by a dozen
modules that have never heard of each other, and two services claiming one
port is not an event — the lists concatenate and whichever process binds
first wins at runtime.

The example gives that namespace an owner. `networking.nix` is the only floe
in the link that emits `networking`; `nginx` and `postgres` provide a
`PORT_CLAIM`, which `networking` collects and merges under a policy of its
own choosing. The mechanism is `collects`, which already existed. Nothing
here adds a primitive.

### What it establishes

**A service can contribute to a namespace it does not own.** Two do, and a
test asserts that only `networking` emits `networking`.

**Mutual dependencies between floes work.** There are two, in a four-floe
link: `nginx` needs the domain while `networking` needs nginx's ports, and
`nginx` needs webapp's route while `webapp` needs nginx's base domain.
Laziness resolves both. This is the half of NixOS's recursion problem floe
does solve — the blast radius of a cycle is now one link, and a legal cycle
stays legal.

**Sealing has teeth.** `postgres` knows its `dataDir` and does not promise
it, so nothing can read it. In stock NixOS that read is one attribute away
and nobody declared it.

**A value that does not exist yet is an error at eval.** Postgres's password
is `T.deferred`. Put it where NixOS config wants a string and the linker
says so, naming the floe it came from and when it resolves — instead of
NixOS reporting an attrset where it wanted text, some frames later.

**The fragments are real NixOS config.** The `examples-nixos-system` check
hands them to `nixosSystem` and forces the toplevel derivation path. A
snapshot cannot tell a real option path from a plausible one; this can.

### The honest accounting

What a deployer writes is [`nixos/system.nix`](nixos/system.nix): **10
meaningful lines**, pinned by a test that fails if it grows. Here is the
stock NixOS equivalent, composing modules that already exist, so the
comparison can be checked rather than taken on trust — the webapp's own
systemd unit is left out of both sides, since under floes it lives in
`webapp.nix` on the author's side:

```nix
{
  networking.hostName = "example";
  networking.domain = "example.test";
  networking.firewall.enable = true;
  networking.firewall.interfaces.eth0.allowedTCPPorts = [ 80 443 5432 ];
  services.nginx.enable = true;
  services.nginx.recommendedProxySettings = true;
  services.nginx.virtualHosts."app.example.test".locations."/".proxyPass = "http://127.0.0.1:8080";
  services.postgresql.enable = true;
  services.postgresql.enableTCPIP = true;
  services.postgresql.settings.port = 5432;
}
```

**Twelve lines against ten.** That is a marginal difference, and the line
count is not the point.

The point is which lines are absent. The floe version names no port, no
virtual host, no ordering:

|                              | floe                    | stock NixOS     |
| ---------------------------- | ----------------------- | --------------- |
| firewall ports               | derived from claims     | written by hand |
| the `app.example.test` vhost | derived from a claim    | written by hand |
| ordering                     | derived from signatures | `after = [ … ]` |

So moving webapp to another port is one number in one place, and the proxy
target follows. `testOneEditPropagates` asserts exactly that, including that
it does **not** open a port — webapp is behind the proxy, and a floe
contributes only to namespaces it actually touches.

And the cost, which is real: **the author side is about 350 meaningful
lines** for four floes and five signatures. In stock NixOS that is nixpkgs'
job and the deployer pays none of it. Floe moves work from the deployer to
the author. That trades well only where components are written once and
deployed many times — which is nixpkgs' situation, and is the argument, but
it is an argument and not a measurement.

## What it does not establish

**The other half of the recursion problem is untouched.**
[`nixos/broken.nix`](nixos/broken.nix) has a floe that reads the merge it
contributes to. It recurses, and Nix says `infinite recursion encountered`
naming no floe, no hole and no field. Note what decides it: `nginx` requires
the _same hole from the same floe in the same cycle_ and is fine, because it
reads `domain` rather than `openPorts`. The **field** is what makes it fatal
— so a polarity annotation would have to be per field, not per hole.

Worse, and discovered while writing the tests: `builtins.tryEval` catches
only `throw` and `assert`, so this failure is not observable from inside Nix
at all. No test can hold it and no library code can wrap it in a better
message, because nothing runs after it. A readable error has to come from
rejecting the cycle _before_ any body evaluates. That is what makes RFC
0001's stratification check structural rather than cosmetic.

**Merge lawfulness is not addressed and cannot be.** Inside a floe the NixOS
module system's ad hoc merges are exactly as they were. Floe encapsulates
that problem; it does not solve it.

**Incrementality is not built.** A floe's output depends only on its
declared inputs and requires, which makes it a natural memoization unit —
and that is floe's strongest answer to the complaint people actually have
about NixOS eval time. Nothing here does it, and the single `lib.fix` in
`lib/link.nix` currently stands in the way, because a floe's inputs are
thunks in a global knot rather than values.

## The contrast with `k8s/`

|               | nixos             | k8s           |
| ------------- | ----------------- | ------------- |
| unit          | a systemd service | a Helm chart  |
| floes         | 5                 | 3             |
| signatures    | 5                 | 2             |
| collected     | 2                 | 0             |
| eval cycles   | 2, both mutual    | 0, a chain    |
| output typing | narrow, per floe  | loose, shared |

The last two rows are the interesting ones. Kubernetes components have
coarse grain and clean boundaries, so nothing needs a collection and nothing
points backwards. And a rendered manifest is opaque by nature, so there is
no useful `T.record` to write for it — floe does not insist on one.

Both use `mkSig`, `requires`, `collects` and `mkOutputKind`, unmodified.
Floe was designed against the right-hand column; the left is the harder
case, and the reason a second domain was worth testing against at all.

## A note on output schemas

An output kind is a dotted name plus a schema. The name is what collects
fragments into one bucket; the schema has no reason to be shared, and in the
NixOS example it must not be — `postgres` emits `services.postgresql` and
`networking` emits `networking`, which have nothing in common.

So each floe narrows the schema itself, the way a NixOS module declares its
own options. [`nixos/kinds.nix`](nixos/kinds.nix) is the whole of it. This
needed no library change: `lib/link.nix` already checks each floe's `out`
against that floe's own kind and groups by `kind.name`. It had just never
been written down.

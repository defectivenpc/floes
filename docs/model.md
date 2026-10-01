# The Model

Catallaxy nests four things, each inside the one before it.

```
Lab            everything: clusters, host services, secrets, the plan
 └─ Cluster        one Kubernetes cluster
     └─ Floe           one capability
         └─ Bundle        a group of resources that install together
```

Every option path and every error message sits somewhere in that stack.

## Lab

One lab is one `mkLab` evaluation, configured under `lab.*`. It holds the
clusters, the host-side services they depend on (DNS resolver, registry, TLS
proxy), the encrypted secrets, and the ordered plan that builds it all.

```nix
lab.name = "minimal.local";
lab.dns.zone = "minimal.test";
lab.clusters.app.floes = { /* … */ };
```

## Cluster

One Kubernetes cluster, at `lab.clusters.<name>`. What a cluster mostly is,
is an attrset of instantiated floes:

```nix
lab.clusters.app.floes = {
  cluster      = floes.k3d-cluster  { name = "app"; instanceName = "minimal-app"; };
  cert-manager = floes.cert-manager { chart = "${cataCharts.cert-manager.chart}"; };
  gateway      = floes.gateway      { chart = "${cataCharts.traefik.chart}"; };
  podinfo      = floes.podinfo      { };
};
```

Three things about that block are decisions rather than accidents.

**A floe is instantiated, not enabled.** `floes.podinfo { }` is a function
call and its result is an opaque value. There is no `enable`: a floe absent
from the attrset is simply not there. If something needed what it provided,
that is an error naming both — and it should be, because omitting a
certificate issuer really does break everything needing certificates.

**Nothing declares an ordering.** Nothing may. The order comes from the
signatures;
[How It Works](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/understanding/how-it-works.md)
explains how.

**A cluster is not a module.** There is no cluster-scoped `config` to read
and no `lab` argument to reach around it. Values another cluster or the lab
holds arrive the way everything else does: a signature the floe requires,
resolved against a scope. See
[Configure a Lab](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/using/configuring.md).

## Floe

The unit of capability: a certificate manager, a gateway, your own
application. A floe is a **type signature with an implementation behind
it**, and the signature is the part you should be able to read on its own:

```nix
catallaxy.mkComponentFloe {
  name = "podinfo";
  summary = "podinfo, a small routed workload for proving a cluster serves traffic.";

  inputs = { /* what the deployer decides */ };

  requires.gateway = sigs.API_GATEWAY;   # what it needs, named by capability

  modules = [ /* the body */ ];
}
```

`requires` and `provides` name **signatures**, not floes. `podinfo` requires
`API_GATEWAY`; it does not require `traefik`, and it never spells the
gateway's name, its namespace, its listener, or the lab's DNS zone. Whatever
provides `API_GATEWAY` in that cluster is what it gets, and swapping the
implementation changes nothing on this page.

Resolution is **exactly one provider per signature per cluster**. Zero is an
error naming what went unsatisfied; two is an error naming both. That rule
is the whole of the wiring, and it is why the cluster block above needs no
`after`, no priority, and no list of dependencies.

What a floe requires and provides is generated into its own reference page —
the declaration read off the definition, and what it emits read off an
actual link. Those pages are diff-checked, so a floe whose interface moves
and whose page does not is a failing build.

Floes catallaxy ships and floes you write are the same kind of thing. See
[Write a Floe](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/using/writing-a-floe.md).

## Bundle

A group of Kubernetes resources installed as a unit, written to
`bundles.<name>` inside a floe's component. Bundles are the nodes of the
install graph, which is why a floe usually emits several: a certificate
manager's CRDs, its operator and its issuers cannot install at the same
moment.

A bundle orders itself against its **siblings in the same floe**, with
`needs`. It cannot name another floe's bundle, and that restriction is the
design: ordering between floes comes from the link graph, where it is
checked, rather than from a string that happens to match.

## Where the words come from

The vocabulary is borrowed, not invented, and knowing the source explains
most of it at once. Catallaxy's floe system is Haskell's
[Backpack](https://plv.mpi-sws.org/backpack/) — a mixin module system —
applied to NixOS modules rather than to Haskell modules.

| Here                        | There                                                                   |
| --------------------------- | ----------------------------------------------------------------------- |
| **Signature**               | a Backpack signature (`.hsig`): an interface with no implementation     |
| **Hole**                    | a hole: an unfilled signature a unit requires                           |
| **Link**                    | mixin linking: matching requirements to implementations by name         |
| **`requires` / `provides`** | a unit's requirements and provisions                                    |
| **Instantiation**           | instantiating a unit by filling its holes                               |
| **Sealing**                 | ML's opaque sealing (`:>`): a structure seen only through its signature |

That correspondence is why the rules are what they are. A hole must be
filled by exactly one provider because mixin linking resolves by name, not
by search. A provided value is sealed because a signature is the _whole_
interface — if a consumer could read past it, the signature would not be
one. And a floe is the unit, which is why `lab.clusters.<c>.floes.<name>` is
an instantiation and not a definition.

One piece of Backpack that had no counterpart here until recently is
**inclusion**: a unit that includes other units and re-exports what they
provide. Every lab had grown a private stand-in for it — a closure returning
an attrset of floes — which is what
[presets](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/using/presets.md)
now are, with the declaration checked rather than assumed.

One place the analogy stops. Backpack links a whole program at once; a floe
link is one fixpoint over one set of units, and there is no longer a wider
scope a link falls back to — `scope` and the `T.local` locality marking that
served it were removed as unexercised. `docs/adr/0003` says why, and
`docs/migrating.md` says what to do instead.

Two things Backpack has no counterpart for, and floe now does. `T.deferred`
marks a value that does not exist until after apply, from which the linker
derives a deploy edge. `T.derivedFrom` marks a field its provider folded out
of a collection, which the linker withholds from the peers that feed that
fold — mixin linking has nothing to say about a unit reading back its own
contribution, because Backpack units do not aggregate.

The one word that was doing its job backwards was `unit` — see the
glossary's table of retired terms.

## Next

- [The mkFloe API](floe-api.md): the surface this describes.
- [RFC 0001](rfcs/0001-floes.md): the design it argues for.

Both pages this used to point at — How It Works, Configure a Lab — are
catallaxy's, and describe a distribution rather than the model.

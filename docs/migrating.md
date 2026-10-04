# Migrating

Extracting the library from catallaxy and reviewing it produced one batch of
breaking changes rather than a trickle. No aliases: there is one known
consumer, it has the same author, and carrying compatibility weight for it
would be the speculative generality the review was deleting.

## Mechanical

| Before                                                    | After                                                 |
| --------------------------------------------------------- | ----------------------------------------------------- |
| `mkSig { as = "proxy"; … }`                               | `mkSig { canonicalName = "proxy"; … }`                |
| `mkSig { fields = { a = T.str; }; }`                      | unchanged; a bare `T` goes there too                  |
| `mkOutputKind { name; description; schema; }`             | `mkSig { name; canonicalName; description; fields; }` |
| `out.<localName> = someKind`                              | `out.<canonicalName> = someSig`                       |
| `requiresOptional.oidc = SIG`                             | `optional.oidc = SIG` (**and see below**)             |
| `floe.mkDeferred [ "a" "b" ]`                             | `floe.mkDeferred <retrievalSig> <ref>`                |
| `config.floe.out.<k>` where `<k>` was a kind's local name | keyed by the signature's `canonicalName`              |

`fields` keeps its name and its meaning. It briefly became `shape` and took
a `T` directly, so that one constructor could serve a narrow interface and
an opaque `T.attrsOf T.any` output alike; it now does both under the old
name, dispatching on whether the argument is itself a type. `mkSig` wraps an
attrset of `T`s in `T.record` for you, so `fields = T.record { … }` and
`fields = { … }` both work and the second is the one to write.

`link`'s result is unchanged except that `wiring.scope` is gone and
`wiring.all` is new. `wiring.optional` is still there.

## Removed, with reasons

**`requiresOptional`, removed and then restored as `optional`.** It came
back with 26 live call sites across seven catallaxy floes pointed at it, so
the "nobody used it" that justified deleting it was true of `examples/` and
false of the consumer. The rename is mechanical; **the semantics changed and
the change is not**.

An optional hole now resolves **only when a deployer names the provider**,
by `.bind` or by the link's `defaults`. Before, the linker wired any single
provider present in the link without being asked. So a lab that had grafana
and kanidm together and got OIDC for free will now get an error naming
kanidm as the candidate, and wants one line:

```nix
link { defaults.OIDC_PROVIDER = "kanidm"; }
```

This will feel like a regression, so the reason matters: automatic
resolution means adding a floe to a link rewrites another floe's output with
nothing saying so, the action at a distance that makes `enable` flags
frightening once a configuration is too large to read. `requires` never had
the problem, because a second provider is an error there.
[ADR 0009](adr/0009-an-optional-hole-resolves-only-when-named.md) is the
argument; the `optional` section of [the API](floe-api.md) is the surface.

Measured, so the ceremony is a number rather than a worry: catallaxy's
eleven consumer-holes needed **four** `defaults` entries, because one entry
covers every consumer of that signature.

**`link`'s `scope`, and `T.local` / `isUncrossable` with it.** This is the
painful one, and it is catallaxy's lab→cluster nesting. Nothing in
`examples/` used `scope`, and `T.local` existed only so `scope` could refuse
fields meaning nothing in another link, which made `T` carry a concept the
NixOS examples never needed.

The requirement was real even so, and what replaces it needs no library
feature: **a value from outside becomes an ordinary unit of the consuming
link.** Build a floe whose whole body is that value, under the signature the
boundary allows, and add it to the units:

```nix
fromOutside = sig: value: (floe.mkFloe {
  name = "from-outside";
  summary = "A value this link was given from outside it.";
  provides.${sig.canonicalName} = sig;
  body = _: { provides.${sig.canonicalName} = value; };
}).instantiate { };

link { units = config.floes // { "from-outside/zone" = fromOutside DNS_ZONE labZone; }; }
```

One resolution rule, one kind of provider, and a real eval edge pointing at
it. That is the whole of what `scope` was for, minus the second resolution
path that consulted it only after local providers failed.

Two consequences worth planning for. **Nearer-wins is gone**: offer the
outside value only to links that have no provider of their own, because two
providers of one signature is the ambiguity error it already was everywhere
else. And **what may cross is now a decision you write down**: keep a table
mapping a signature to the narrower form another link may read, and check it
with `floe.narrows`. `T.local` was that decision inferred from a per-field
marking; a table is the same decision said once, at the boundary that has
it.

The other answer is a floe that includes a link, which is `mkFloe`'s `units`
and `exports`. Reach for it when the boundary is a reusable component with
open holes, and for the pattern above when it is one value crossing once. It
shipped as `mkInclusion`, came out when a floe without a body made "floe"
two kinds of thing, and came back once a floe could include and define at
once. [ADR 0006](adr/0006-a-link-can-be-a-unit.md) has that history.

## Added

**A retrieval signature for every deferred value.** `mkDeferred` used to
take a label path, `mkDeferred [ "status" "ip" ]`, which told a backend
nothing it could act on. It now takes a signature describing _where_ the
value will be readable, plus a ref checked against that signature's fields:

```nix
SECRET_REF = mkSig {
  name = "k8s.secretRef"; canonicalName = "secretRef";
  description = "Readable from a key of a Secret, once applied.";
  fields = { namespace = T.str; name = T.str; key = T.str; };
};

caFingerprint = floe.mkDeferred SECRET_REF {
  namespace = "cert-manager"; name = "ca-tls"; key = "ca.crt";
};
```

Declare one retrieval signature per mechanism your distribution supports,
and have each provider name the one it uses. The token's `path` and `phase`
fields are gone: `path` was only the deploy edge's label, which is now the
retrieval name, and apply order was always derived as `link.phases`.

**`link.deferredSites` and `link.deferredRetrievals`**, for a backend to
find the values it must reify. Core ships no substitution function; see
[ADR 0005](adr/0005-the-provider-declares-the-retrieval.md).

**`T.derivedFrom <sig> <inner>`.** Marks a field a provider computed by
folding its collection of `<sig>`. `link` refuses that one field to any peer
that contributes to the same collection, before anything evaluates. Mark
every field you compute from a `collects`; the failure it prevents is
otherwise `infinite recursion encountered` with nothing named, and not
catchable by `tryEval` either.

**`link { defaults = { SIGNATURE = "<unit>"; }; }`.** Which provider a hole
means when its consumer did not say. Applied only where a unit gave no
`.bind`, so an ambiguity no one resolved is still an error. Add these when a
second provider of something appears: without them, that addition breaks
every existing consumer.

**`mkFloe { body = { inputs, requires, collects, floe }: { provides, out }; }`.**
An alternative to `modules`, for a floe that does not need the module
system's merge, which is most of them. About 30% cheaper. `provides` still
has to be _declared_ as well as returned, because the linker resolves holes
from headers before any body runs.

**`mkFloe { singleton = true; }`.** For a floe whose body writes fixed paths
rather than keying them by `floe.name`. Two instances of one would emit
identical output, and identical values merge without complaint, so the
deployer would get one of the thing with no error anywhere. Declare it, or
key the output by `floe.name` and instantiate it as often as you like.

## New checks to expect

**A provider must answer the requirer's signature.** The one most likely to
surface real breakage, because it finds skew that used to link and fail
somewhere else. The provider's fields must be a width-supertype of the
requirer's; extras are what sealing drops. Expect it to find any place two
copies of a signature drifted apart, and read the error as a real find
rather than a false positive: the alternative was `attribute 'x' missing` in
a body, naming nothing.
[ADR 0007](adr/0007-a-provider-must-answer-the-requirers-signature.md).

**One hole or provide name may not mean two different signatures**:
`requires.proxy` being `REVERSE_PROXY` in one floe and `HTTP_PROXY` in
another. Rename one to its signature's `canonicalName`.

Not the reverse: a floe may hold two holes on one signature, a primary and a
replica, so a signature is not pinned to a single name. So two signatures
which _want_ the same canonical name (`DATABASE` and a hypothetical
`DATABASE_V2`, both wanting `database`) cannot both have it. One has to be
`databaseV2`, and that is the intended answer rather than a limitation to
work around.

**A hole name may not be on both `requires` and `optional`.** Both resolve
into one `requires` attrset, so one of them would vanish without an error.

**A `.bind` may not name a collected hole.** `link` was ignoring it, because
a collection takes every provider and never consulted a binding. If you have
one, either it meant nothing, so delete it, or the hole wanted to be
`requires` or `optional`.

# Migrating

The library was extracted from catallaxy and then reviewed, which produced
one batch of breaking changes rather than a trickle. No aliases: there is
one known consumer, it has the same author, and carrying compatibility
weight for it would be the speculative generality the review was deleting.

## Mechanical

| Before                                                    | After                                                 |
| --------------------------------------------------------- | ----------------------------------------------------- |
| `mkSig { as = "proxy"; … }`                               | `mkSig { canonicalName = "proxy"; … }`                |
| `mkSig { fields = { a = T.str; }; }`                      | unchanged — and a bare `T` goes there too             |
| `mkOutputKind { name; description; schema; }`             | `mkSig { name; canonicalName; description; fields; }` |
| `out.<localName> = someKind`                              | `out.<canonicalName> = someSig`                       |
| `requiresOptional.oidc = SIG`                             | `optional.oidc = SIG` — **and see below**             |
| `floe.mkDeferred [ "a" "b" ]`                             | `floe.mkDeferred <retrievalSig> <ref>`                |
| `config.floe.out.<k>` where `<k>` was a kind's local name | keyed by the signature's `canonicalName`              |

`fields` keeps its name and its meaning. It briefly became `shape` and took
a `T` directly, so that one constructor could serve a narrow interface and
an opaque `T.attrsOf T.any` output alike; it now does both under the old
name, dispatching on whether the argument is itself a type. An attrset of
`T`s is wrapped in `T.record` for you, so `fields = T.record { … }` and
`fields = { … }` both work and the second is the one to write.

`link`'s result is unchanged except that `wiring.scope` is gone and
`wiring.all` is new. `wiring.optional` is still there.

## Removed, with reasons

**`requiresOptional` — removed, then restored as `optional`.** It came back
with 26 live call sites across seven catallaxy floes pointed at it, so the
"nobody used it" that justified deleting it was true of `examples/` and
false of the consumer. The rename is mechanical; **the semantics changed and
the change is not**.

An optional hole now resolves **only when a deployer names the provider**,
by `.bind` or by the link's `defaults`. Before, any single provider present
in the link was wired automatically. So a lab that had grafana and kanidm
together and got OIDC for free will now get an error naming kanidm as the
candidate, and wants one line:

```nix
link { defaults.OIDC_PROVIDER = "kanidm"; }
```

The reason is worth knowing, because it will feel like a regression:
automatic resolution means adding a floe to a link rewrites another floe's
output with nothing saying so, which is the action at a distance that makes
`enable` flags frightening once a configuration is too large to read.
`requires` never had the problem, because a second provider is an error
there. See the `optional` section of [the API](floe-api.md).

**`link`'s `scope`, and `T.local` / `isUncrossable` with it.** This is the
painful one, and it is catallaxy's lab→cluster nesting. Nothing in
`examples/` used `scope`, and `T.local` existed only so `scope` could refuse
fields meaning nothing in another link — which made `T` carry a concept the
NixOS examples never needed.

The requirement was real even so, and
[ADR 0006](adr/0006-a-link-can-be-a-unit.md) settles what replaces it: an
**inclusion**, a floe whose body is a link, which may leave an inner hole
unfilled for the parent to fill and re-exports a provide under a narrower
**export signature**. That last part is what makes `T.local` unnecessary
rather than merely absent — the boundary declares what crosses and sealing
drops the rest, instead of every field carrying a locality marking for a
boundary most of them never meet.

**It is not built.** Until it is, a nested link's parent facts are passed as
`inputs`: the deployer threads them by hand and nothing checks locality.
That is the honest state of things rather than a recommendation.

## Added

**A retrieval signature for every deferred value.** `mkDeferred` used to
take a label path — `mkDeferred [ "status" "ip" ]` — which told a backend
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
and have each provider name the one it actually uses. The token's `path` and
`phase` fields are gone: `path` was only the deploy edge's label, which is
now the retrieval name, and apply order was always derived as `link.phases`.

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
`.bind`, so ambiguity nobody decided is still an error. Add these when a
second provider of something appears: without them, that addition breaks
every existing consumer.

**`mkFloe { body = { inputs, requires, collects, floe }: { provides, out }; }`.**
An alternative to `modules`, for a floe that does not need the module
system's merge — which is most of them. About 30% cheaper. `provides` still
has to be _declared_ as well as returned, because the linker resolves holes
from headers before any body runs.

**`mkFloe { singleton = true; }`.** For a floe whose body writes fixed paths
rather than keying them by `floe.name`. Two instances of one would emit
identical output, and identical values merge without complaint, so the
deployer would get one of the thing with no error anywhere. Declare it, or
key the output by `floe.name` and gain the ability to instantiate freely.

## New checks to expect

**A provider must answer the requirer's signature.** The one most likely to
surface real breakage, because it finds skew that previously linked and
failed somewhere else entirely. The provider's fields must be a
width-supertype of the requirer's; extras are what sealing drops. Expect it
to find any place two copies of a signature drifted apart, and read the
error as a genuine find rather than a false positive — the alternative was
`attribute 'x' missing` in a body, naming nothing.
[ADR 0007](adr/0007-a-provider-must-answer-the-requirers-signature.md).

**One hole or provide name may not mean two different signatures** —
`requires.proxy` being `REVERSE_PROXY` in one floe and `HTTP_PROXY` in
another. Rename one to its signature's `canonicalName`.

Not the reverse: a floe may hold two holes on one signature, a primary and a
replica, so a signature is not pinned to a single name. The consequence
worth knowing is that two signatures which _want_ the same canonical name —
`DATABASE` and a hypothetical `DATABASE_V2`, both wanting `database` —
cannot both have it. One has to be `databaseV2`, and that is the intended
answer rather than a limitation to work around.

**A hole name may not be on both `requires` and `optional`.** Both resolve
into one `requires` attrset, so one of them would be dropped silently.

**A `.bind` may not name a collected hole.** It was being ignored, because a
collection takes every provider and never consulted a binding. If you have
one, either it meant nothing — delete it — or the hole wanted to be
`requires` or `optional`.

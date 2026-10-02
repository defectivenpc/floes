# mkFloe API

Declared in `lib/`, and reached as `floe.mkFloe` after
`mkFloeLib nixpkgs.lib`.

```nix
floe.mkFloe       # a unit with declared surfaces
floe.mkInclusion  # a unit whose body is a link
floe.mkSig        # a named schema for anything a floe commits to
floe.link         # resolve, seal, collect
floe.T            # the data schemas a signature is built from
```

A **distribution** supplies the rest: a catalogue of signatures — both the
ones its floes exchange and the ones they emit — and whatever sugar suits
its domain. [Catallaxy](https://github.com/defectivenpc/catallaxy) is one,
for Kubernetes.

## `mkFloe`

```nix
mkFloe { name, summary, inputs ? {}, requires ? {}, optional ? {},
         collects ? {}, provides ? {}, out ? {}, modules ? [],
         body ? null, singleton ? false }
```

| Argument    | Required | Type                   | Meaning                                               |
| ----------- | -------- | ---------------------- | ----------------------------------------------------- |
| `name`      | yes      | kebab-case string      | the floe's identity                                   |
| `summary`   | yes      | string                 | one line saying what it installs                      |
| `inputs`    | no       | attrset of `mkOption`s | what the deployer decides — native NixOS option types |
| `requires`  | no       | attrset of signatures  | exactly one provider each                             |
| `optional`  | no       | attrset of signatures  | zero or one; `null` when unwired                      |
| `collects`  | no       | attrset of signatures  | every provider, keyed by unit; may be empty           |
| `provides`  | no       | attrset of signatures  | what it offers back                                   |
| `out`       | no       | attrset of signatures  | what it emits                                         |
| `modules`   | no       | list of modules        | the body, with the module system's merge              |
| `body`      | no       | function               | the body, as a plain function; no `evalModules`       |
| `singleton` | no       | bool                   | whether two instances in one link is an error         |

The pattern is **closed**: an unknown key is an error. `summary` is
defaulted to `null` in the pattern and refused explicitly rather than left
out of it, so the pattern stays closed _and_ the author gets a message
saying what to write — Nix's own "called without required argument" says
neither.

Three arities. The arity is a property of the hole rather than of the
signature, so the same signature can be exactly-one for one floe and
collected by another.

`collects` is the fan-in one. An earlier fan-in was removed for two reasons:
it carried no ordering, and it implied only the floe installing a capability
could render resources using it — which is not how Kubernetes works, since a
registered CRD is a primitive anyone may use. A collection carries one eval
edge per contributor, which answers the first. The second still holds, so
where a runtime aggregator exists a floe ships a constructor and the
consumer emits the resource into its own bundle.

A binding on a collected hole is an error rather than a no-op. A
collection's arity is every provider in the link, so there is nothing for a
binding to choose — and one written there used to be silently ignored.

### `optional`

Zero or one: the hole a floe can do without. Grafana's OIDC, a collector's
trace backend, and what NixOS spells as `mkIf config.services.foo.enable`.

```nix
optional.oidc = sigs.OIDC_PROVIDER;
```

Resolved values land in `requires` beside the exactly-one holes, as the
value or as `null`, because a body wanting "the thing if it is there" should
read one place:

```nix
body = { requires, ... }: {
  out.k8s = lib.optionalAttrs (requires.oidc != null) { … };
};
```

**It resolves only when a deployer names the provider**, by `.bind` or by
the link's `defaults`. A provider merely being present wires nothing, and a
link holding an unnamed provider for an optional hole is an error naming the
candidate. That is deliberate and it is the whole difference from an
`enable` flag: adding a floe to a link can never silently change another
floe's output. `requires` gets the same property for free by erroring on a
second provider; this is the version of it for a hole that may be absent.

The cost is a line per optional hole a deployer actually wants wired, which
`defaults` pays once for a whole link rather than once per consumer — eleven
consumer-holes collapsed to four entries when catallaxy was ported.
[ADR 0009](adr/0009-an-optional-hole-resolves-only-when-named.md).

### `singleton`

A floe whose body writes fixed paths — `services.nginx`,
`networking.firewall` — cannot be instantiated twice. Both instances emit
the same paths, and _identical_ values merge without complaint wherever that
output lands, so the deployer gets one of the thing and believes they have
two. Nothing downstream can catch it; the values agree. `singleton = true`
makes the linker refuse the second instance, naming both.

It is the author's to declare, because only the author knows whether the
body keys its output by `config.floe.name`. A floe that does key by it — see
`examples/nixos/postgres.nix`, which emits
`systemd.services.postgres-<unit>` — leaves `singleton` alone and can be
instantiated freely. That is the one thing floe gives NixOS that its own
module system cannot express at all, so the declaration is worth reading as
"this floe gave that up, deliberately".

Conflicting values are caught by whatever consumes the output; a NixOS
adapter gets the module system's own conflict error. This is only for the
case where they agree.

### Saying which provider

Exactly-one is per hole, not per signature: a second provider breaks every
floe that `requires` that signature, whether or not anyone collects it. The
deployer says which a given consumer means:

```nix
(floes.harbor { chart = …; }).bind { issuance = "internal-ca"; }
```

Spelled `<unit>` or `<unit>/<provide>`. It is the deployer's and not the
author's, because a floe does not know its peers' names.

A `.bind` relieves one consumer, which made adding a second provider a
breaking change to every existing one. `link`'s `defaults` is the same
decision made once for the whole link:

```nix
floe.link {
  units = { … };
  defaults.DATABASE = "main";
}
```

Applied only where a unit gave no `.bind` of its own — so a hole nobody has
an opinion about resolves, and ambiguity nobody decided is still an error. A
default naming a unit that provides nothing here is ignored rather than
refused, because it may be a default for a signature this particular link
does not use.

### What the body sees

Two forms, and the linker cannot tell them apart — `evalFloe` normalises
both to `{ provides, out }`.

**`body`**, a plain function, for a floe that does not need the module
system's merge. That is most of them, and it costs about 30% less:

```nix
body =
  { inputs, requires, collects, floe }:
  {
    provides.<hole> = …; # sealed on the way out
    out.<sig> = …;
  };
```

`floe` carries `floe.name` — the link's name for this instance — and
`floe.mkDeferred`. A floe that can be instantiated twice must key its output
by `floe.name`; see `singleton` above.

**`modules`**, ordinary NixOS modules in the floe's own `evalModules`, for a
floe that wants merge inside itself:

| Path                          | Is                                                                  |
| ----------------------------- | ------------------------------------------------------------------- |
| `config.floe.name`            | the link's name for this instance                                   |
| `config.floe.inputs.<n>`      | what the deployer passed                                            |
| `config.floe.requires.<hole>` | the resolved, **sealed** value, or `null` for an unwired `optional` |
| `config.floe.collects.<hole>` | every provider's, keyed by unit                                     |
| `config.floe.out.<sig>`       | what you write                                                      |
| `config.floe.provides.<hole>` | what you write, sealed on the way out                               |

Either way there is no ambient option tree. A fact from outside the floe
arrives through a signature or it does not arrive.

Declaring `provides` in `mkFloe` _and_ defining it in the body is not
duplication: the linker resolves every hole from headers before any body
evaluates, which is what makes a link's wiring checkable without running
anything.

## `mkInclusion`

A floe whose body is a link, so a lab holding clusters is the same mechanism
as a cluster holding floes rather than a second one beside it. Backpack's
`include`, and what replaces the `scope` that
[ADR 0003](adr/0003-trim-unexercised-surface.md) deleted.

```nix
floe.mkInclusion {
  name = "cluster-env";
  summary = "One cluster and the workloads in it, linked as a unit.";

  inputs.version = lib.mkOption { type = lib.types.str; default = "1.31"; };

  requires.issuer = sigs.ISSUER;            # left open; the parent fills it
  provides.clusterSummary = sigs.CLUSTER_SUMMARY;
  exports.clusterSummary = "cluster";       # from this unit inside

  units = { inputs, requires, collects, floe }: {
    cluster = floes.cluster.instantiate { inherit (inputs) version; };
    podinfo = floes.podinfo.instantiate { };
  };
}
```

Everything an ordinary floe has, it has: `inputs`, `.instantiate`, `.bind`,
the three hole arities, `provides`. What it does not have is `out` — an
inclusion emits nothing of its own, and its units' output propagates with
their names qualified. `examples/k8s` is the worked case.

### Holes left open

The holes an inclusion declares are the ones its units leave unfilled, and
the parent resolves them like any other. This is the half worth having: a
cluster with an open `SECRET_STORE` is reusable across labs, and a lab can
_supply_ its clusters rather than only reading from them.

A filled hole becomes a **unit inside** that provides what the parent
resolved it to — not a second resolution path consulted when the first
fails, which is what `scope` was, but a provider like any other with a real
eval edge pointing at it. A collected hole becomes one unit per contributor,
so the collector inside sees the same fan-in the parent did. Those units are
an implementation device and appear in nothing you read; the edge they stand
for is emitted at the parent level, where it is a fact about the inclusion's
own hole.

### `exports`, and where `T.local` went

`provides` is a signature exactly as any floe declares one, and is usually
_narrower_ than the one inside. `exports` says which inner provide each one
comes from, spelled the way `.bind` spells a provider — `<unit>` or
`<unit>/<provide>`. One names a provider outside, the other names one
inside.

Because the export is itself a sealing step, this is what keeps a value
meaningful only inside from leaving. In `examples/k8s`, `CLUSTER` carries an
`apiServer` address that means nothing to a peer outside the cluster it
describes, and `CLUSTER_SUMMARY` does not carry it:

```nix
provides.clusterSummary = sigs.CLUSTER_SUMMARY;   # { version }
exports.clusterSummary  = "cluster";              # provides { version, apiServer }
```

The lab reads `version` and cannot reach `apiServer`. That is the whole
replacement for a per-field locality marking: the boundary declares what
crosses, rather than every field carrying a marking for a boundary most of
them never meet. The cost is one extra signature name per concept that
actually crosses a link boundary.

### What spans the nesting

`out` is one flat bucket with inner units qualified (`app/podinfo`), because
a backend wants one bucket and should not care how deep anything sat.
`deferredSites` and `phases` follow it, and `phases` is keyed by what emits
— an inclusion is not a thing that applies, its units are.

`graph` is hierarchical where the link is: an inclusion is a node, and so
are its units.

`singleton` stays **per link**. Two inner links are two apply targets, so
one `nginx` in each is correct — the output keys differ because the
destinations do.

## `mkSig`

```nix
mkSig { name, canonicalName, description, fields }
```

| Argument        | Meaning                                                          |
| --------------- | ---------------------------------------------------------------- |
| `name`          | the identity resolution keys on. Two sigs sharing a name collide |
| `canonicalName` | the name a hole or provide of it should be called by             |
| `description`   | one line                                                         |
| `fields`        | an attrset of `T.*` schemas, or a bare `T` for an opaque one     |

### Compatibility

Resolution keys on `name`, a bare string, so two definitions of one name — a
third-party floe pinning an older copy, two distributions shipping the same
concept — both answer the same holes. `link` checks that the provider's
fields **answer** the requirer's before anything evaluates: the provider
must be a width-supertype, every field the requirer declared present and
compatible, extras being what sealing drops.

Without it the link succeeded and the consumer died on Nix's
`attribute 'port' missing`, several frames away, naming no floe, no field
and no provider — and not catchable by `tryEval`.

Variance is ordinary covariance, with one asymmetry: a concrete provider
answers a requirer that declared the field `T.deferred`, because such a
requirer handles both, and the reverse is refused. Closed sets run the other
way — a provider's `T.enum` values and `T.taggedUnion` variants must be a
_subset_ of the requirer's. A refinement answers what it refines, so a
`T.dnsName` satisfies a `T.str`.

This is also the signature-evolution rule, which is why there is no version
field: **adding** a field to a signature is compatible with every existing
requirer, removing or retyping one is not, and the error names the field. An
emitted signature has no requirer, so co-emitters of one `out` name are
never compared — they must be free to differ.
[ADR 0007](adr/0007-a-provider-must-answer-the-requirers-signature.md).

One constructor for everything a floe commits to: a value it exchanges with
a peer (`requires`, `collects`, `provides`) and a product it emits (`out`).
There used to be a second, `mkOutputKind`, and it was the same record with a
different word on it — sealing built a record out of a signature's fields,
which is exactly what a kind's schema was.

`fields` is usually an attrset of `T`s, which is what a signature is and
what the ML and mixin vocabulary calls it:

```nix
fields = { host = T.str; port = T.port; };
```

A signature with nothing worth naming — a rendered manifest — passes a bare
`T` in the same place, and one constructor serves both:

```nix
fields = T.attrsOf T.any;
```

It dispatches on whether the argument is itself a type, rather than taking
two arguments, because two spellings of one thing is what
[ADR 0003](adr/0003-trim-unexercised-surface.md) deleted elsewhere. Nothing
about `fields` says a direction: a signature is neither input nor output,
and the surface it sits on is what gives it one.

`canonicalName`, `description` and `summary` are all required, and all three
throw explicitly rather than being bare pattern arguments —
`builtins.tryEval` cannot catch "called without required argument", so the
requirement would otherwise be untestable.

`canonicalName` exists because a hole's name is the first thing a reader
sees, and before it, `provides.operator` bound four different signatures.
`link` enforces the direction that matters: **no single name may mean two
different signatures**, across every surface of every floe in the link.

Not the reverse. A floe may hold two holes on one signature — a primary and
a replica database — so a signature is not pinned to one name. The
consequence is that two signatures wanting the same canonical name cannot
both have it, and renaming one is the intended answer.

**Resolution keys on `name`, not on identity.** That is why there are three
separate `*_OPERATOR` signatures rather than one: a single `OPERATOR` would
make cnpg and kaniop two providers of one signature, and every lab holding
both would fail to link. The nominal distinction _is_ the mechanism.

## The type language, `T`

**Why there are two.** A value a deployer writes — a floe input — is
described by a native NixOS option type. A value a floe _commits to_ — a
signature's fields, whether they cross to a peer or are emitted — is
described by a floe data schema, `T`. That is the whole rule, and both
halves are enforced where they are used: `mkFloe` refuses a `T` in `inputs`,
and `checkValue` refuses a `lib.types` in anything a signature describes.

`lib.types` cannot do the signature side, for two reasons:

- **A field can carry facts the linker reads.** `T.deferred` says a value
  does not exist until after apply, and `T.derivedFrom` says a field was
  folded out of a collection; the linker reads both and acts on them before
  any body evaluates. A NixOS type has nowhere to carry that.
- **Sealing drops, it does not error.** A provider may compute more than its
  signature promises; `T.record` returns only the declared fields.
  `lib.types.submodule` refuses the whole value instead.
- **A NixOS type holds functions.** `merge`, `check`, `substSubModules` — so
  it cannot be serialized, and a schema here has to be inert data.

**`T` is not the faster one.** Worth knowing, because the split above might
suggest otherwise: `T.checkValue` costs about _twice_ what `lib.types.check`
does for a scalar, since it chains `if ty.tag == …` comparisons where a
NixOS type dispatches straight to its predicate. It does not matter — a
signature is checked once per provide per link, not once per value per
instance, and a twenty-nine-floe link is 37 ms — but `T` exists for what it
can express, not for speed. `docs/adr/0004` has the measurements.

| Constructor                                   | Is                                                                      |
| --------------------------------------------- | ----------------------------------------------------------------------- |
| `T.str`, `T.int`, `T.bool`, `T.port`          | scalars                                                                 |
| `T.url`, `T.dnsName`                          | scalars with a pattern                                                  |
| `T.package`                                   | a derivation or the store path it coerces to                            |
| `T.enum`, `T.nullOr`, `T.listOf`, `T.attrsOf` | the usual combinators                                                   |
| `T.record`                                    | a fixed set of named fields                                             |
| `T.taggedUnion`                               | externally tagged; matches serde's default                              |
| `T.deferred`                                  | not known until after apply — the linker derives a deploy edge from one |
| `T.derivedFrom`                               | folded out of a collection — the linker withholds it from contributors  |
| `T.moduleType`                                | a NixOS type, for a field that is a schema                              |

A distribution may add its own. Catallaxy's `k8sName` lives in its prelude
rather than here, because it was the one thing making the claim that this
library knows nothing about Kubernetes false. What a floe actually gets is
the prelude: this plus the distribution's own.

### `T.package`, and where a package set does not go

`T.package` is how something built crosses a floe boundary, and it exists
because the two alternatives both fail: `T.str` refuses a derivation, and
`T.any` admits one and then meets the token scan — which used to walk a
derivation's self-referential `out` until the stack ran out, a crash
`tryEval` cannot even catch. Every NixOS module that writes
`environment.systemPackages` puts one in `out`.

The package **set** is a different thing and is not a signature. Which
nixpkgs, which overlays and which system are the deployer's choice, so a
floe takes the packages it needs as ordinary inputs, one at a time:

```nix
inputs.postgresql = lib.mkOption { type = lib.types.package; };
```

Not `inputs.pkgs`. A package set can be neither hashed for a cache key nor
serialised into the IR, and one package is both — a derivation hashes as its
`drvPath` and `toJSON`s as its `outPath`. The cost is that a deployer writes
`pkgs.postgresql` per floe that needs it, and `defaults` cannot help because
packages are inputs rather than signatures.
[ADR 0008](adr/0008-per-floe-eval-stays-cacheable.md).

### `T.deferred`, and retrieval signatures

```nix
# in the signature — *when*, and nothing else
password = T.deferred T.str;

# in the provider's body — *where*
password = floe.mkDeferred FILE_REF { path = "/run/secrets/pw"; mode = "firstLine"; };
```

A deferred value does not exist until after apply. `T.deferred` says so, and
`checkValue` refuses the token anywhere a concrete value is declared — which
is the static safety: a floe cannot read a value that is not there yet, and
finds out at `nix eval` rather than from a manifest containing an attrset.

That leaves the question of how anything ever _does_ read it. The answer is
that the **provider** declares where the value will be readable, as a ref
against an ordinary signature:

```nix
FILE_REF = floe.mkSig {
  name = "nixos.fileRef";
  canonicalName = "fileRef";
  description = "Readable from a file on the host, once the unit writing it has run.";
  fields = { path = T.str; mode = T.enum [ "text" "firstLine" ]; };
};
```

Core checks the ref against those fields and records the signature's `name`.
It never looks inside, and never learns what a file or a Secret is. **A
retrieval signature says where a value will be readable; a backend
implements how.**

The provider declares it and not the signature's field, because the provider
is what creates the value — cert-manager knows it writes a Secret, postgres
knows it writes a file. So one `DATABASE.password` survives both domains,
which it could not if the retrieval were welded to the type. `examples/` has
one of each.

#### What a backend reads

```nix
link.deferredSites       # [{ unit; out; at; token; }] — read this, write it there
link.deferredRetrievals  # the distinct retrievals this link needs resolvers for
```

`at` is a **list** of keys, not a dotted string, because output keys contain
dots: a Kubernetes annotation is `floe.dev/ca-fingerprint`, and splitting
that would write to the wrong place.

A backend walks `deferredRetrievals` before applying anything, checks each
against the resolvers it implements, and refuses to start rather than
failing halfway. That check cannot live in core: only the backend knows what
it can resolve, so a list of resolvers in the link would be a claim core
could not verify.

Core ships **no** substitution function, deliberately. A ConfigMap, a
Secret, an annotation, a file and an HTTP lookup are five mechanisms for one
job, and several may be right for one value depending on whether it is a
secret. Choosing one in core would choose for every distribution at once.
`tests/examples.nix` has a worked substitution, in a test rather than the
library, as a demonstration that `deferredSites` is sufficient to write one.

Apply **order** is derived, not declared: a token in unit A sourced from
unit B is a deploy edge, and `link.phases` is the topological depth of that
subgraph. The token carries no phase of its own.

### `T.derivedFrom`

```nix
openPorts = T.derivedFrom PORT_CLAIM (T.listOf T.port);
```

Marks a field its provider computed by folding its `collects` of
`PORT_CLAIM`. A peer that _contributes_ a `PORT_CLAIM` to that same provider
and then reads this field closes a loop: computing its contribution needs
the fold, and the fold needs its contribution.

So `link` refuses that one field to exactly those peers, before anything
evaluates — both facts it needs, who provides `PORT_CLAIM` and who collects
it, are in the headers. The error names both floes, the collection and the
field.

It is **per field, not per hole**, and that is the point. A floe may require
the same hole from the same provider in the same cycle and be entirely fine,
as long as it reads a field the fold did not produce. Without this the
failure is `infinite recursion encountered`, naming nothing, and
`builtins.tryEval` cannot even catch it — so it could not be tested and
could not be wrapped in a better message. `examples/nixos/broken.nix` has
the case both ways round.

Mark every field you compute from a `collects`.

## Distribution sugar

A distribution will usually wrap `mkFloe` with its own defaults —
catallaxy's `mkComponentFloe` pre-fills the cluster hole and its component
output signature, merged over rather than replacing, so a floe needing a
second cluster hole can still name one.

`examples/nixos/kinds.nix` is the small version: one helper that builds the
`nixos.config` signature with the fields the calling floe supplies, so every
floe narrows its own output without restating the name.

## Testing a floe

Build a stub floe per required signature and link the result, so a suite
exercises the real linker rather than an approximation. `tests/support` is a
small worked distribution doing exactly that; catallaxy's
`floes/tests/support.nix` is the same idea at scale, enforced one suite per
floe.

RFC 0001 proposed a `checkFloe` that would check a floe in isolation. It was
never built, and this replaced it: checking against the real linker catches
what an isolated approximation cannot.

### `T.stubFor`

The values are the tedious part, so core derives them:

```nix
T.stubFor DATABASE.shape                            # every field, typed
T.stubFor API_GATEWAY.shape // { baseDomain = "lab.test"; }   # the one that matters
```

Possible at all because a schema is pure data, which is most of why `T`
exists rather than `lib.types`. The values are deliberately uninformative —
`"stub"`, port `1` — because a suite that cares what a field says overrides
it, and what this removes is the obligation to write the other nine. Every
distribution was hand-maintaining a stub per signature, which is a table
that goes stale the moment a signature gains a field.

One case cannot be derived and says so: `T.moduleType`'s inhabitants are the
module system's to know. The error names the field.

The stub _floe_ stays yours, because it is three lines and core shipping it
would start a framework:

```nix
mkStub = sig: value: (floe.mkFloe {
  name = "stub-${sig.canonicalName}";
  summary = "Stub provider for a suite.";
  provides.${sig.canonicalName} = sig;
  body = _: { provides.${sig.canonicalName} = value; };
}).instantiate { };
```

Name the provide by `canonicalName`, not something fixed: naming every
stub's provide `it` makes one name mean every signature in the catalogue,
and `link` refuses that.

### `narrows`

```nix
floe.narrows full shared   # [] when `shared` promises no more than `full`
```

What an export signature is to the provide it re-exports, and what a
distribution's "this may cross a boundary" table holds. The same relation
compatibility decides between a requirer and a provider, pointed inward, and
`link` checks it for every `exports` entry — an export promising _more_ than
what it re-exports is a field a peer can ask for and nothing can answer.

Nothing checks that a provider of a signature **behaves** like one; see RFC
0001 §7.

## Related

- [RFC 0001](rfcs/0001-floes.md): the design, with a status block naming
  what shipped and what was abandoned.
- [The Model](model.md): where the words come from.
- Catallaxy's
  [Write a Floe](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/using/writing-a-floe.md)
  is the worked guide, against a Kubernetes distribution.

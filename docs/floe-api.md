# mkFloe API

Declared in `lib/`, and reached as `floe.mkFloe` after
`mkFloeLib nixpkgs.lib`.

```nix
floe.mkFloe   # a unit with declared surfaces
floe.mkSig    # a named schema for anything a floe commits to
floe.link     # resolve, seal, collect
floe.T        # the data schemas a signature is built from
```

A **distribution** supplies the rest: a catalogue of signatures — both the
ones its floes exchange and the ones they emit — and whatever sugar suits
its domain. [Catallaxy](https://github.com/defectivenpc/catallaxy) is one,
for Kubernetes.

## `mkFloe`

```nix
mkFloe { name, summary, inputs ? {}, requires ? {}, collects ? {},
         provides ? {}, out ? {}, modules ? [], body ? null,
         singleton ? false }
```

| Argument    | Required | Type                   | Meaning                                               |
| ----------- | -------- | ---------------------- | ----------------------------------------------------- |
| `name`      | yes      | kebab-case string      | the floe's identity                                   |
| `summary`   | yes      | string                 | one line saying what it installs                      |
| `inputs`    | no       | attrset of `mkOption`s | what the deployer decides — native NixOS option types |
| `requires`  | no       | attrset of signatures  | exactly one provider each                             |
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

Two arities, and `collects` is the fan-in one. An earlier fan-in was removed
for two reasons: it carried no ordering, and it implied only the floe
installing a capability could render resources using it — which is not how
Kubernetes works, since a registered CRD is a primitive anyone may use. A
collection carries one eval edge per contributor, which answers the first.
The second still holds, so where a runtime aggregator exists a floe ships a
constructor and the consumer emits the resource into its own bundle. No floe
in this distribution collects.

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
`floe.mkRuntime`. A floe that can be instantiated twice must key its output
by `floe.name`; see `singleton` above.

**`modules`**, ordinary NixOS modules in the floe's own `evalModules`, for a
floe that wants merge inside itself:

| Path                          | Is                                    |
| ----------------------------- | ------------------------------------- |
| `config.floe.name`            | the link's name for this instance     |
| `config.floe.inputs.<n>`      | what the deployer passed              |
| `config.floe.requires.<hole>` | the resolved, **sealed** value        |
| `config.floe.collects.<hole>` | every provider's, keyed by unit       |
| `config.floe.out.<sig>`       | what you write                        |
| `config.floe.provides.<hole>` | what you write, sealed on the way out |

Either way there is no ambient option tree. A fact from outside the floe
arrives through a signature or it does not arrive.

Declaring `provides` in `mkFloe` _and_ defining it in the body is not
duplication: the linker resolves every hole from headers before any body
evaluates, which is what makes a link's wiring checkable without running
anything.

## `mkSig`

```nix
mkSig { name, canonicalName, description, shape }
```

| Argument        | Meaning                                                          |
| --------------- | ---------------------------------------------------------------- |
| `name`          | the identity resolution keys on. Two sigs sharing a name collide |
| `canonicalName` | the name a hole or provide of it should be called by             |
| `description`   | one line                                                         |
| `shape`         | a `T.*` schema — `T.record { … }` for an interface               |

One constructor for everything a floe commits to: a value it exchanges with
a peer (`requires`, `collects`, `provides`) and a product it emits (`out`).
There used to be a second, `mkOutputKind`, and it was the same record with a
different word on it — sealing built a record out of a signature's fields,
which is exactly what a kind's schema was.

`shape` takes a `T` rather than an attrset of them, which is what lets one
constructor serve both a narrow interface and an opaque
`shape = T.attrsOf T.any` output. It is also why it is not called `fields`:
a signature is neither input nor output, and the surface it sits on is what
gives it direction.

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
signature's shape, whether it crosses to a peer or is emitted — is described
by a floe data schema, `T`. That is the whole rule, and both halves are
enforced where they are used: `mkFloe` refuses a `T` in `inputs`, and
`checkValue` refuses a `lib.types` in anything a signature describes.

`lib.types` cannot do the signature side, for two reasons:

- **A field can carry facts the linker reads.** `T.runtime` says a value
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
| `T.url`, `T.dnsName`                          | scalars with a shape                                                    |
| `T.enum`, `T.nullOr`, `T.listOf`, `T.attrsOf` | the usual combinators                                                   |
| `T.record`                                    | a fixed set of named fields                                             |
| `T.taggedUnion`                               | externally tagged; matches serde's default                              |
| `T.runtime`                                   | not known until after apply — the linker derives a deploy edge from one |
| `T.derivedFrom`                               | folded out of a collection — the linker withholds it from contributors  |
| `T.moduleType`                                | a NixOS type, for a field that is a schema                              |

A distribution may add its own. Catallaxy's `k8sName` lives in its prelude
rather than here, because it was the one thing making the claim that this
library knows nothing about Kubernetes false. What a floe actually gets is
the prelude: this plus the distribution's own.

### `T.runtime`, and retrieval signatures

```nix
# in the signature — *when*, and nothing else
password = T.runtime T.str;

# in the provider's body — *where*
password = floe.mkRuntime FILE_REF { path = "/run/secrets/pw"; mode = "firstLine"; };
```

A runtime value does not exist until after apply. `T.runtime` says so, and
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
  shape = T.record { path = T.str; mode = T.enum [ "text" "firstLine" ]; };
};
```

Core checks the ref against that shape and records the signature's `name`.
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
link.runtimeSites       # [{ unit; out; at; token; }] — read this, write it there
link.runtimeRetrievals  # the distinct retrievals this link needs resolvers for
```

`at` is a **list** of keys, not a dotted string, because output keys contain
dots: a Kubernetes annotation is `floe.dev/ca-fingerprint`, and splitting
that would write to the wrong place.

A backend walks `runtimeRetrievals` before applying anything, checks each
against the resolvers it implements, and refuses to start rather than
failing halfway. That check cannot live in core: only the backend knows what
it can resolve, so a list of resolvers in the link would be a claim core
could not verify.

Core ships **no** substitution function, deliberately. A ConfigMap, a
Secret, an annotation, a file and an HTTP lookup are five mechanisms for one
job, and several may be right for one value depending on whether it is a
secret. Choosing one in core would choose for every distribution at once.
`tests/examples.nix` has a worked substitution, in a test rather than the
library, as a demonstration that `runtimeSites` is sufficient to write one.

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
`nixos.config` signature with a shape the calling floe supplies, so every
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

## Related

- [RFC 0001](rfcs/0001-floes.md): the design, with a status block naming
  what shipped and what was abandoned.
- [The Model](model.md): where the words come from.
- Catallaxy's
  [Write a Floe](https://github.com/defectivenpc/catallaxy/blob/main/docs/book/src/using/writing-a-floe.md)
  is the worked guide, against a Kubernetes distribution.

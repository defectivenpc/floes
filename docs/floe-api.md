# mkFloe API

Declared in `lib/`, and reached as `floe.mkFloe` after
`mkFloeLib nixpkgs.lib`.

```nix
floe.mkFloe        # a unit with declared surfaces
floe.mkSig         # a named record schema over data
floe.mkOutputKind  # a schema for what a floe emits
floe.link          # resolve, seal, collect
floe.T             # the data types a signature's fields take
```

A **distribution** supplies the rest: a catalogue of signatures, the output
kinds its floes emit, and whatever sugar suits its domain.
[Catallaxy](https://github.com/defectivenpc/catallaxy) is one, for
Kubernetes.

## `mkFloe`

```nix
mkFloe { name, summary, inputs ? {}, requires ? {}, requiresOptional ? {},
         collects ? {}, provides ? {}, out ? {}, modules ? [],
         singleton ? false }
```

| Argument           | Required | Type                    | Meaning                                               |
| ------------------ | -------- | ----------------------- | ----------------------------------------------------- |
| `name`             | yes      | kebab-case string       | the floe's identity                                   |
| `summary`          | yes      | string                  | one line saying what it installs                      |
| `inputs`           | no       | attrset of `mkOption`s  | what the deployer decides — native NixOS option types |
| `requires`         | no       | attrset of signatures   | exactly one provider each                             |
| `requiresOptional` | no       | attrset of signatures   | zero or one; resolves to `null` when nothing provides |
| `collects`         | no       | attrset of signatures   | every provider, keyed by unit; may be empty           |
| `provides`         | no       | attrset of signatures   | what it offers back                                   |
| `out`              | no       | attrset of output kinds | what it emits                                         |
| `modules`          | no       | list of modules         | the body                                              |
| `singleton`        | no       | bool                    | whether two instances in one link is an error         |

The pattern is **closed**: an unknown key is an error. `summary` is
defaulted to `null` in the pattern and refused explicitly rather than left
out of it, so the pattern stays closed _and_ the author gets a message
saying what to write — Nix's own "called without required argument" says
neither.

Three arities, and `collects` is the fan-in one. An earlier fan-in was
removed for two reasons: it carried no ordering, and it implied only the
floe installing a capability could render resources using it — which is not
how Kubernetes works, since a registered CRD is a primitive anyone may use.
A collection carries one eval edge per contributor, which answers the first.
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

Spelled `<unit>` or `<unit>/<provide>`, as `lab.clusters.<c>.offers` is. It
is the deployer's and not the author's, because a floe does not know its
peers' names — and it relieves one consumer, so adding a second provider
means binding in each of them.

### What the body sees

Each module in `modules` is evaluated in the floe's own `evalModules`, and
reads:

| Path                          | Is                                    |
| ----------------------------- | ------------------------------------- |
| `config.floe.inputs.<n>`      | what the deployer passed              |
| `config.floe.requires.<hole>` | the resolved, **sealed** value        |
| `config.floe.collects.<hole>` | every provider's, keyed by unit       |
| `config.floe.out.<kind>`      | what you write                        |
| `config.floe.provides.<hole>` | what you write, sealed on the way out |

There is no lab-scoped `config` and no ambient option tree. A fact from
outside the floe arrives through a signature or it does not arrive.

## `mkSig`

```nix
mkSig { name, as, description, fields }
```

| Argument      | Meaning                                                          |
| ------------- | ---------------------------------------------------------------- |
| `name`        | the identity resolution keys on. Two sigs sharing a name collide |
| `as`          | the canonical local name a hole or provision binds it under      |
| `description` | one line                                                         |
| `fields`      | attrset of `T.*` types                                           |

`as`, `description` and `summary` are all required, and all three throw
explicitly rather than being bare pattern arguments — `builtins.tryEval`
cannot catch "called without required argument", so the requirement would
otherwise be untestable.

`as` exists because a hole's name is the first thing a reader sees, and
before it, `provides.operator` bound four different signatures. A check
enforces the bijection across every floe.

**Resolution keys on `name`, not on identity.** That is why there are three
separate `*_OPERATOR` signatures rather than one: a single `OPERATOR` would
make cnpg and kaniop two providers of one signature, and every lab holding
both would fail to link. The nominal distinction _is_ the mechanism.

## The type language, `T`

**Why there are two.** A value a deployer writes — a floe input — is
described by a native NixOS option type. A value that _crosses a floe
boundary_ — a signature field, an output-kind schema — is described by a
floe data schema, `T`. That is the whole rule, and both halves are enforced
where they are used: `mkFloe` refuses a `T` in `inputs`, and `checkValue`
refuses a `lib.types` in anything that crosses.

`lib.types` cannot do the crossing side, for three reasons:

- **Locality is per field.** `T.local` marks a field that does not travel to
  another cluster, and the linker, `isUncrossable` and the generated floe
  pages all read it. A NixOS type has nowhere to carry it.
- **Sealing drops, it does not error.** A provider may compute more than its
  signature promises; `T.record` returns only the declared fields.
  `lib.types.submodule` refuses the whole value instead.
- **A NixOS type holds functions.** `merge`, `check`, `substSubModules` — so
  it cannot be serialized, and a schema here has to be inert data.

| Constructor                                   | Is                                                                        |
| --------------------------------------------- | ------------------------------------------------------------------------- |
| `T.str`, `T.int`, `T.bool`, `T.port`          | scalars                                                                   |
| `T.url`, `T.dnsName`                          | scalars with a shape                                                      |
| `T.enum`, `T.nullOr`, `T.listOf`, `T.attrsOf` | the usual combinators                                                     |
| `T.record`                                    | a fixed set of named fields                                               |
| `T.taggedUnion`                               | externally tagged; matches serde's default                                |
| `T.local`                                     | **does not cross a cluster boundary**                                     |
| `T.deferred`                                  | a value not known until apply — the linker derives a deploy edge from one |
| `T.moduleType`                                | a NixOS type, for a field that is a schema                                |

A distribution may add its own. Catallaxy's `k8sName` lives in its prelude
rather than here, because it was the one thing making the claim that this
library knows nothing about Kubernetes false. What a floe actually gets is
the prelude: this plus the distribution's own.

`T.local` is per field, not per signature. `KUBERNETES_CLUSTER`'s every
field is local, which is what makes the whole signature uncrossable;
`API_GATEWAY` mixes them, so a consumer in another cluster gets the portable
half and is refused the rest.

## `mkOutputKind`

```nix
mkOutputKind { name, description, schema }
```

An output kind is what a floe emits, and a distribution registers its own —
catallaxy has four, for Kubernetes components, cluster descriptors,
state-based stacks and secret-store publications.

A floe's _category_ is just which kind it emits. There is no registration
mechanism beyond that; RFC 0001 describes one, and it was never built.

A distribution will usually wrap `mkFloe` with its own defaults —
catallaxy's `mkComponentFloe` pre-fills the cluster hole and the component
output kind, merged over rather than replacing, so a floe needing a second
cluster hole can still name one.

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

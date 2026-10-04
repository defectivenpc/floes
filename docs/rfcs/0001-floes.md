# RFC 0001: Floe

**Status:** **Implemented**, amended. **Author:** Michael Whitehead
**Created:** 2026-08-26 **Target:** floe core library (Nix), Catallaxy
distribution

> **What shipped, and what did not.** The core is built:
> `lib/{floe,link,interfaces,types}.nix`, extracted into its own repository.
> Five named deliverables in §8 were **abandoned by design**, not left
> pending, and the reasons are worth knowing before reading them as a to-do
> list:
>
> | §8 item                   | What happened                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
> | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
> | `signatureOptions` (§4.4) | Never built. Conformance is checked **once**, at link (`link.nix` `sealSig` → `types.checkValue`), not twice. The "two schema layers" drawback in §5 therefore does not exist.                                                                                                                                                                                                                                                                                                                                                                                                                    |
> | `checkFloe` (§4.9)        | Never built. Replaced by linking against stubs, so a suite exercises the real linker rather than an approximation. The stubs and the harness are a distribution's; catallaxy enforces one suite per floe. Core briefly shipped a `T.stubFor` to derive stub values from a signature, and it is gone: a distribution's stubs carry _meaningful_ values (a plausible subnet, a context name a floe branches on) and a record's fields are all required anyway, so a derived stub bought only that a signature gaining a field would fail quietly instead of loudly. For a harness, loudly is right. |
> | `mkHelmFloe` (§4.5)       | Never built, and unbuildable as specified: it wires `out.k8s.helmRelease`, a kind this distribution does not have. The sugar that exists is `catallaxy.mkComponentFloe`, which defaults `requires.cluster` and `out.component` and does nothing chart-specific.                                                                                                                                                                                                                                                                                                                                   |
> | Hole renaming (§3.2, §6)  | **Built**, as `instance.bind { <hole> = "<unit>"; }`. Resolution is still by signature name; a binding narrows the candidates before the arity rule applies, and is the deployer's because a floe does not know its peers' names.                                                                                                                                                                                                                                                                                                                                                                 |
> | `T.template` (§3.1, §7)   | Never built, and now closed: `collects` took half of what it was for and retrieval signatures took the other half, and nothing has asked for the residue. §7.5 says so.                                                                                                                                                                                                                                                                                                                                                                                                                           |
>
> **Where the words come from.** This RFC does not say so, and it is the
> single most explanatory fact about the design: the model is Haskell's
> Backpack (signatures, holes, mixin linking, instantiation) applied to
> NixOS modules, with sealing from ML. The mapping, and why the rules follow
> from it, is in [The Model](../model.md).
>
> Other drift a reader should know about:
>
> - **`requiresMany` is gone**, replaced by `requiresOptional`
>   (zero-or-one). It carried no ordering edge, and it implied only the floe
>   installing a capability could render resources using it, which is not
>   how Kubernetes works. `lib/floe.nix` records the argument. **Amended
>   twice.** A fan-in arity is back, as `collects`, and the first half of
>   that argument no longer holds: a collection carries one eval edge per
>   contributor. And `requiresOptional` itself was deleted as unused and
>   then restored as **`optional`** when its 26 call sites turned up in the
>   consumer, with one change: it resolves only when a deployer names the
>   provider. ADR 0009. The second half stands and is why it is narrow:
>   where a runtime aggregator exists, a consumer rendering its own resource
>   is still the better answer, and nothing in this distribution was
>   converted. §4.6's "collection is keyed by unit name and therefore
>   disjoint" now describes the requires side as well as `out`, and §6's
>   rejection of monoidal merge still stands: the consumer folds a
>   collection, and the linker never merges it. See ADR 0003.
> - **The kinds named in §3.1 and §4.11** (`k8s.manifests`,
>   `terraform.json`, `catallaxy.meta`) are not the shipped ones. Those are
>   `catallaxy.component`, `catallaxy.cluster`, `catallaxy.resources` and
>   `catallaxy.publications`. The first and third survive only as test
>   fixtures.
> - **§4.2 forbids functions in kind schemas**; `T.moduleType` does so, and
>   `lib/types.nix` argues the prohibition confused _values_ with _schemas_.
>   Values stay pure; a schema is never serialised.
> - **§4.6 says there is no monoid.** True of core, which collects by unit
>   and never merges. One layer up the distribution does define one, in
>   `lib/floe-catallaxy/component.nix`, with identity and associativity, and
>   `elaborate.nix` gives the layering argument.
> - **§4.3's claim that a floe's complete interface is readable without
>   evaluating the body is now true**, via `nix/floe-interface.nix`,
>   `docs/floes/` and 37 `floe-interface-*` checks. It is true of the
>   _declaration_ half; what a floe emits is derived after linking, because
>   an ops command's name is not knowable until then.
> - **§4.5's projection rule is the RFC's only normative MUST and nothing
>   checks it.** The practical enforcement is the per-floe interface
>   document, which renders a provide's value beside the bundles it was
>   projected from.
>
> **What the library gained after this RFC, which it does not describe.**
> Each came out of asking what was missing before a large distribution was
> ported, and each has an ADR because each changed what a link means:
>
> - **A provider must answer the requirer's signature** (ADR 0007), which is
>   §7.4's versioning question answered without a version field.
> - **Nesting arrived, left, and came back.** §4.6 is still one fixpoint
>   over one set of units, and a link is still not a scope anything falls
>   back to. What a floe gained is `units`: a body that is a link, which is
>   Backpack's `include` and MixML's closure property. `scope` is gone for
>   good (ADR 0003); `mkInclusion` shipped, came out, and returned as
>   ordinary `mkFloe` surfaces once a floe could include and define at once
>   (ADR 0006). A distribution may still add an outside value to a link as
>   an ordinary unit, which needs no feature at all.
> - **A third arity**, `optional` (ADR 0009), resolving only when named.
> - **`T.package`**, and the rule that a package set is an input and never a
>   signature, which is what keeps per-floe eval cacheable (ADR 0008).
> - **A retrieval signature** on every deferred value (ADR 0005), without
>   which §4.8's "backends substitute token sites" was not implementable:
>   the token carried a label and a constant, and nothing could have filled
>   the value in.
> - **`behaviorTest`**, carried and never run, for the gap §4.4's
>   conformance story does not cover: `link` checks a provider's _shape_ and
>   nothing checks its behaviour.

## 1. Summary

Floe is a mixin-style module linking system for Nix. It lets infrastructure
components declare typed interfaces (signatures), require and provide those
interfaces as data, expose typed inputs for instantiation, and be linked
into a deployment graph whose coherence, interface conformance, and apply
ordering are checked at Nix eval time instead of at deploy time.

A floe wraps an isolated `evalModules` call. The NixOS module system remains
the implementation language inside a floe. Floe owns only what happens
between floes: signatures, hole resolution, output collection,
deferred-value tracking, and link-time policy.

The first distribution built on floe is Catallaxy, which defines Kubernetes,
Terraform, and cluster-metadata output kinds plus topology policies for a
four-cluster platform.

## 2. Motivation

Today, wrapping a Helm chart (or any component) in Nix gives no checked
contract between components. If grafana exposes an ingress URL and a
downstream app consumes it, nothing verifies at eval time that the value
exists, has the right shape, or that the app only touches what grafana
intended to expose. Errors surface at deploy time or later.

Nix eval is the compile step of an infrastructure pipeline: it runs in CI
before anything ships. Checking interfaces at eval therefore occupies the
same position in the lifecycle as static type checking does in a compiled
language. Floe exploits this: every inter-component error class below moves
from deploy time to eval time.

- Referencing an output a component never promised.
- Providing an output with the wrong shape (bad URL, out-of-range port,
  misshapen Helm values).
- Missing or ambiguous implementations of an interface.
- Using a value that only exists after apply (LoadBalancer IP, generated
  ARN) in a position that must be concrete at eval.
- Violating topology rules (lab floe wired into prod, cross-cluster
  reference to cluster-private data).

Secondary motivation: the NixOS module system solves intra-component
composition (merging partial configs) well, and solves inter-component
interfaces poorly (one global option tree, merge-everything semantics, no
hiding). Floe adds the missing inter-component layer without modifying or
reimplementing the module system.

## 3. Guide-level explanation

### 3.1 Concepts

**Signature.** A named record schema over data. Field types come from a
small prelude of types (`str`, `port`, `url`, `dnsName`, `enum`, `attrsOf`,
`submodule`, `nullOr`, `deferred t`, `local t`, `template holes t`).
Signatures contain no functions and no abstract types. Because they are pure
data, they serialize, and they can be compiled into NixOS option
declarations.

**A distribution extends the prelude** with the types its domain has, and
core carries only what any domain would recognise. `k8sName` was listed here
and implemented in core, which made the claim below (that floe core contains
no Kubernetes) false; it lives in `lib/floe-catallaxy/prelude.nix` now.

Two of the constructors say where and when a value may be used rather than
what it is. `deferred t` is a value that does not exist until after apply.
`local t` is a value that means something only inside the link that produced
it (a service address, a namespace, a reference to something installed
here), and a link seals it away when the value is offered to another link (§
RFC 0005 §3.2).

```nix
OBSERVER = mkSig {
  name = "OBSERVER";
  fields = {
    ingressUrl = T.url;
    dashboards = T.attrsOf (T.submodule { url = T.url; });
  };
};
```

**Output kind.** A registered name plus a schema for one class of build
product. Distributions define kinds; floe core does not, and contains no
Kubernetes.

```nix
k8s  = mkOutputKind { name = "k8s.manifests";  schema = T.attrsOf k8sManifest; };
tf   = mkOutputKind { name = "terraform.json"; schema = T.attrsOf tfResource; };
meta = mkOutputKind { name = "catallaxy.meta"; schema = metaSchema; };
```

**Floe.** A unit with declared surfaces (inputs, requires, provides, out)
and a body of ordinary modules. Input types are native NixOS option
declarations; see "The type-language rule" below.

```nix
mkFloe {
  name = "grafana";
  inputs = {
    size = lib.mkOption {
      type = lib.types.str; default = "10Gi";
      description = "PVC size for Grafana storage.";
    };
    adminUser = lib.mkOption {
      type = lib.types.str;                       # no default: required
      description = "Initial admin username.";
    };
  };
  requires.ingress        = sigs.INGRESS;         # exactly-one hole
  requiresMany.dashboards = sigs.DASHBOARD_REQ;   # fan-in hole
  provides.observer       = sigs.OBSERVER;
  out = { k8s = kinds.k8s; meta = kinds.meta; };
  modules = [ ./grafana.nix ];
}
```

The body is stock module-system code:

```nix
{ config, lib, ... }:
let
  ingress = config.floe.requires.ingress;
  host = "grafana.${ingress.baseDomain}";
in {
  config.floe.provides.observer = {
    ingressUrl = "https://${host}";
    dashboards = lib.mapAttrs
      (n: _: { url = "https://${host}/d/app-${n}"; })
      config.floe.requires.dashboards;
  };

  config.floe.out.k8s.helmRelease = {
    chart = "grafana/grafana";
    version = "8.5.1";
    values = {
      persistence.size = config.floe.inputs.size;
      adminUser        = config.floe.inputs.adminUser;
      # remaining values derived from requires or fixed by the author
    };
  };

  config.floe.out.meta = { cluster = "observability"; environment = "lab"; };
}
```

**Link.** Takes a set of configured floes, resolves holes, checks coherence,
evaluates bodies, seals provides against signatures, collects outputs,
derives the dependency graph, and runs policies.

```nix
result = link {
  units = {
    ingress = floes.nginxIngress.instantiate { };
    grafana = floes.grafana.instantiate { size = "50Gi"; adminUser = "michael"; };
    myapp   = floes.myapp.instantiate { };
  };
  policies = catallaxy.policies;
};
```

### 3.2 What the deployer sees

Constructing an instance means supplying inputs. `instantiate` eagerly
validates the supplied attrset against the floe's input declarations, before
body eval and before linking: a missing required input, an unknown input
name, or a type mismatch fails with the module system's own message wrapped
in the floe's name (see "Inputs" below). Inputs and requires are distinct by
provenance: the deployer chooses inputs per instance and they may default;
the graph resolves requires from peers, they have no defaults, and `link`
coherence-checks them.

Multiplicity is `instantiate` under two unit names. Two postgres instances
are one floe definition and two entries in `units`, each with its own
inputs. Hole renaming is only needed when the instances' requires must
resolve to different providers.

### 3.3 What the author sees

Five names: `mkFloe`, `config.floe.inputs`, `config.floe.requires`,
`config.floe.provides`, `config.floe.out`. Everything else is the module
system. A floe can wrap an existing module or Helm chart by listing it in
`modules` and adding one small module that maps its config onto
`floe.provides` and `floe.out`. The author chooses the input surface:
body-internal options are private wiring between the floe's own modules, and
nothing outside can set them.

## 4. Reference-level explanation

### 4.1 Option namespaces

`mkFloe` runs `lib.evalModules` per floe and injects generated declarations.
Each surface has exactly one writer:

| Namespace         | Declared from                    | Written by                 | Notes                                                 |
| ----------------- | -------------------------------- | -------------------------- | ----------------------------------------------------- |
| `floe.inputs.*`   | author's `mkOption` declarations | deployer via `instantiate` | read-only to body; eagerly checked at instantiation   |
| `floe.requires.*` | signatures                       | linker                     | read-only to body; author definitions are eval errors |
| `floe.provides.*` | signatures                       | body modules               | sealed against signature at link                      |
| `floe.out.<kind>` | output kinds                     | body modules               | writing an undeclared kind is an eval error           |
| everything else   | author `options`                 | body modules               | private wiring; not settable from outside             |

Each floe is an isolated `evalModules`, so there is no global option tree.
Eval isolation does the namespacing, not a naming convention. Intra-floe
merge (multiple body modules contributing to `out.k8s.*`, `mkIf`,
priorities) works; it is the module system doing its job.

### 4.2 The type-language rule

The serialization boundary picks the type language.

- **Signatures and output kinds** cross floe boundaries and land in the JSON
  IR, so they are pure floe data schemas: serializable, checkable outside
  any Nix eval, compiled into option declarations by `signatureOptions` for
  eval-time enforcement.
- **Inputs** never leave Nix: supplied at instantiation, checked at
  instantiation, consumed by the body. They are therefore typed directly
  with native NixOS option declarations (`mkOption`, `lib.types`), with no
  floe type layer in between. This gives the full `lib.types` catalog
  (`submodule`, `coercedTo`, `either`, `enum`, freeform types), merge and
  priority semantics on supplied values, descriptions/defaults/examples, and
  no second vocabulary for authors to learn.

Consequence: input types do not serialize as machine-checkable schemas
(option types contain functions). The IR carries rendered input
documentation instead (type description string, default, description), the
same way the NixOS manual renders options. This is acceptable because Nix
eval validates inputs and nothing downstream re-checks them.

### 4.3 Inputs

`instantiate suppliedInputs` performs an eager pre-check before body eval
and before linking: a mini `evalModules` containing only the floe's input
declarations and the supplied definitions, with `floe.inputs` deep-forced.
Errors are the module system's own, wrapped in
`addErrorContext "while instantiating floe <name>"`:

- Missing required input:
  `The option 'floe.inputs.adminUser' is used but not defined`.
- Unknown input: `The option 'floe.inputs.sizes' does not exist`.
- Type mismatch: the option type's error, naming the input.

The pre-check is cheap because no body modules participate.

Two rules keep the pre-check sound:

1. **Input defaults are static**, declared in the `mkOption`. A fallback
   derived from requires (e.g. defaulting a hostname from the ingress
   domain) is expressed as a `nullOr` input with default `null`, with the
   effective value computed in the body. This keeps instantiation checkable
   without resolving the graph.
2. **Inputs are read-only to the body**, symmetric with requires. Writers
   per surface are unique: linker writes requires, deployer writes inputs,
   the author's body writes provides and out.

The complete interface of a floe (inputs docs, requires, provides, out
kinds) is available from its declaration header without evaluating the body,
and the link result and IR carry it.

### 4.4 Signature compilation and double checking

`signatureOptions` compiles the data schema of each signature and kind into
`mkOption` declarations, so two things enforce conformance: NixOS option
types during body eval (their error messages, their coercions), and floe's
own check on the serialized projection after eval (`seal`), which also drops
any provided fields not in the signature (opaque ascription). Downstream
floes can only see what the signature promises.

### 4.5 Application: wrapping charts, and the projection rule

Nothing in floe core is chart-specific. A chart wrapper is an ordinary floe,
and the author chooses the exposure level of its input surface:

- **Minimal:** expose `inputs.size` only; every other chart value is derived
  from requires or fixed by the author (the grafana example above).
- **Curated:** expose a submodule input for the subset of values the floe
  supports tuning.
- **Passthrough:** also expose `inputs.values` typed as the chart's values
  shape (a submodule for modeled fields with
  `freeformType = attrsOf anything` for the long tail), for deployers who
  need the escape hatch. Authors who want the full surface can generate the
  submodule; many charts ship `values.schema.json`, and a converter from it
  to option types is future work.

The common implementation pattern uses a private option as the assembly
point: the body declares an internal `chartValues` option typed by the chart
shape, defines computed entries from requires at `mkDefault` priority,
forwards any passthrough input at normal priority, and projects
`out.k8s.helmRelease.values` from `config.chartValues`. Module-system merge
then gives deployer-over-computed precedence for free.

> **Amended: enforced by review, and that is the ceiling.** This is the
> RFC's only normative MUST and nothing checks it, which used to be recorded
> as a gap. It is not a checkable one: the rule is that two expressions
> share a source node, which is a question about the shape of an author's
> code rather than about any value a link can inspect. In practice the
> generated per-floe interface document enforces it, by rendering a
> provide's value beside the output it was projected from, so a pair
> computed twice and drifting apart is visible on one page.

**Projection rule (normative, general):** any provide whose meaning depends
on emitted output MUST be projected from the same `config` nodes the output
is projected from, never computed in parallel:

```nix
config.floe.provides.observer.ingressUrl =
  "https://${lib.head config.chartValues.ingress.hosts}";
```

The option tree is the single source of truth; emitted outputs and sealed
provides are both projections of it, so a changed input or overridden value
updates what deploys and what downstream floes see atomically. Computing the
same fact twice (once for `out`, once for `provides`) is forbidden because a
change would split them with nothing saying so.

`mkHelmFloe { chart; version; valuesType; }` is the sugar: it declares the
internal `chartValues` option and wires `out.k8s.helmRelease` from it.

### 4.6 Linking semantics

1. **Resolve.** For each `requires` hole, find exactly one unit providing
   that signature. Zero providers: error listing the missing signature and
   its requirers. Two or more: error demanding explicit wiring. For each
   `requiresMany` hole, collect all providers into an attrset keyed by unit
   name (possibly empty unless the hole is marked required).
2. **Fix.** Tie the graph with `lib.fix`. Laziness permits mutually
   recursive floes at eval time. Convention: prefer routing inter-floe
   cycles through deferred values; eval-time cycles are legal but
   discouraged.
3. **Seal.** `link` checks each provide against its signature and restricts
   it to the declared fields.
4. **Collect.** `result.out.<kindName>.<unitName>.*`. Collection is keyed by
   unit name and therefore disjoint by construction. There is no cross-floe
   merge of outputs and no monoid. Merge exists only inside a floe; between
   floes there is only coherence and collection.
5. **Scan.** Walk every unit's serialized outputs for deferred tokens (see
   below) to derive deploy edges.
6. **Policy.** Run distribution-supplied checks over the link result.

### 4.7 The link result

```nix
{
  provides = { <sigInstanceName> = <sealed attrset>; ... };
  out      = { "<kind>" = { <unit> = <data>; ... }; ... };
  inputs   = { <unit> = <rendered input docs>; ... };
  graph = {
    nodes = [ ... ];
    edges = [ { from; to; via; kind = "eval" | "deploy"; } ... ];
  };
}
```

The entire result is serializable JSON. It is the IR consumed by backends
(the existing Rust CLI).

> **Amended: once a backend has substituted.** A deferred token carries a
> `__toString` that throws, and `builtins.toJSON` prefers it, so a result
> holding one is not serialisable, by design. A token reaching JSON means a
> backend is about to ship a placeholder to the world, and the throw is the
> same refusal that answers §7.1. `link.deferredSites` is the list of what
> to substitute first; nothing in core strips them, because a stripper with
> no caller is the speculative generality ADR 0003 is about. `inputs`
> carries each floe's rendered input documentation (name, type description,
> default, description) from its declarations, enabling generated per-floe
> reference docs.

### 4.8 Deferred values

Some values are known at eval (chart version, namespace); some exist only
after apply (LB address, KMS key ARN). `T.deferred t` types the second
class. A deferred value evaluates to a provenance token:

```nix
{ __deferred = true; source = "nginx-ingress"; path = ["address"]; phase = "post-apply"; }
```

Semantics:

- A contract expecting concrete `t` rejects a deferred token at eval, with
  the phase in the error. Misuse fails at eval, not as a placeholder shipped
  in a manifest.
- The link-time scan finds every token in every unit's outputs. A token in
  unit A sourced from unit B is a **deploy edge** A depends-on B,
  independent of output kind. Hole resolution alone produces **eval edges**
  (A needed B's config to render), which say nothing about apply order.
- Topological order of the deploy subgraph derives apply phases (or ArgoCD
  sync waves). Phases are computed, not hand-assigned. Because tokens are
  kind-agnostic, phase derivation spans kinds: a k8s manifest referencing a
  deferred Terraform output orders the k8s slice after the terraform slice
  in one graph.
- Backends substitute token sites between phases.

Open question 1 governs whether deferred values may flow through string
interpolation.

### 4.9 Per-floe checking without linking

`checkFloe` evaluates one floe with synthetic requires: probe attrsets
containing only signature-declared fields with dummy values satisfying their
types, where access outside the signature throws naming the floe, the
signature, and the field. Provides and outs are then shallowly forced
against their schemas. This runs in a component's own CI without any peer
implementation present. It is an approximation (value-dependent branches and
dynamic `getAttr` escape it), but it catches the dominant failure,
referencing a field the signature never promised.

### 4.10 Policies

A policy is a function over the link result returning a list of violations.
Floe core runs them; distributions define them. Examples from Catallaxy:

- Environments never mix: no edge between floes whose
  `catallaxy.meta.environment` differ.
- Public-cluster floes may not `require` SECRET_STORE directly.
- Cross-cluster eval edges restricted to reachable value shapes.

This preserves layering: core owns coherence, distributions own domain
legality. Invalid deployments become unlinkable, with the policy name in the
error.

### 4.11 Distributions

A distribution ships domain signatures, output kinds, policies, and
backends. Catallaxy is the first distribution:

- Kinds: `k8s.manifests`, `terraform.json`, `catallaxy.meta` (cluster in
  {management, observability, internal, public}, environment, owner,
  argocd.project).
- Backends: per-cluster ArgoCD slicer grouping `out."k8s.manifests"` by
  `meta.cluster` with sync waves from the cluster-restricted deploy
  subgraph; phased Terraform consuming `out."terraform.json"`.
- Metadata is an output kind like any other; its distinguishing property is
  its reader (backends and policies interpret it; nothing applies it to the
  world).

Floe core knows none of this. A distribution shipping `systemd.units` and
`caddy.config` kinds requires no core changes.

### 4.12 Compilation pipeline framing

Flake inputs pin floe repos (Nix as fetch/pin substrate). Then: eval floes
(parse), signature conformance (typecheck), hole resolution (link), policies
(lint), backends over IR slices (codegen). The platform is a compilation
problem; these are its passes.

## 5. Drawbacks

- Checking is eval-time and value-level, not static over source. Body
  interiors are unchecked except at the boundaries; `checkFloe` is an
  approximation. No IDE feedback before eval.
- Abstraction is not enforceable against a determined author (Nix has no
  unforgeable values). The guarantee is "cannot violate by accident."
- Two schema layers exist for signatures and kinds (floe data schemas
  compiled to option types). The compiler (`signatureOptions`) must stay
  small and boring or it becomes its own maintenance surface. Inputs avoid
  this layer by design, using native option types, at the cost that input
  types are documented in the IR but not machine-checkable outside Nix; a
  future external linker must trust that input validation happened at eval.
- Deferred-token scanning requires all outputs to be pure data. Any future
  kind whose schema admits functions breaks scanning, `checkFloe`, and
  serialization at once. This RFC therefore forbids functions in kind
  schemas.

## 6. Alternatives considered

**ML functors as the composition primitive.** Rejected. Sharing constraints
reappear (two functors each taking the same dependency must be told it is
the same one), and infra wants per-deployment canonical instances, not
parameterization threaded through call sites. Mixin linking with exactly-one
coherence gives the useful polymorphism directly. `instantiate` plus hole
renaming recovers functor-style multiplicity.

**Functions in signatures** (`dashboardFor : name -> dashboard`). Rejected.
Functions cannot be checked at eval (only wrapped in contracts), do not
serialize into the IR, and defeat `checkFloe`. Defunctionalized: lazy
attrsets replace name-indexed functions; `requiresMany` inverts
producer/consumer where the caller held the knowledge (apps declare
dashboard requests; grafana collects); `T.template` covers residual
parametric data. With functions gone, per-signature abstract types lost
their purpose and went too.

**A parent floe aggregating outputs via monoidal merge.** Rejected. The
dependency graph is knowledge only the linker has; an in-graph aggregator
forces units to self-report wiring the linker already computed. Collection
keyed by unit name is disjoint and needs no merge.

**One global `evalModules` as the substrate** (signatures as option
declarations in a shared tree). Rejected. Module-system merge semantics
(combine all definitions) are the philosophical opposite of link coherence
(exactly one provider, error on ambiguity), and priorities/`mkForce` would
leak into linking. Floe keeps the module system per floe, where merge is
wanted.

**Linker and type checker in Rust over the JSON IR.** Deferred, and kept
open on purpose. Because signatures, outputs, and the link result are all
pure data, the linker can move to the existing Rust CLI later (real
source-span errors, separate compilation, parallel per-floe eval) without
changing any floe. Not justified at current scale; in-Nix linking keeps
`lib.fix` recursion and one fewer moving part.

**Different language substrate** (Nickel, Dhall, Cue/KCL, Haskell EDSL). Not
adopted now. Nickel is the credible candidate (gradual types, first-class
contracts, embeddable Rust interpreter) and remains a candidate authoring
language for floe bodies behind the same data boundary. Dhall's rigidity
fights chart wrapping; Cue/KCL lack linking semantics; a Haskell embedding
maximizes types and interop cost at the same time. None displaces the design
because floe's checked surface is data, which is language-agnostic.

## 7. Open questions

All five are answered. The answers live here because this is the document
that asked, and in an ADR each where the argument is longer than a
paragraph. A sixth question this RFC did not ask is at the end, and is the
only one still open.

1. **Deferred transparency in interpolation.** _Answered: it refuses._
   `"https://${deferredValue}"` is a `throw` the token carries as its
   `__toString`, naming the floe the value came from and what will make it
   readable. Transparent propagation lost for the reason this question
   anticipated: it splits every prelude type into concrete and deferred
   variants and makes every signature field declare which it accepts.

   The decision was not the interesting part. Before it, the failure was
   Nix's "cannot coerce a set to a string": no floe named, nothing able to
   wrap it, and uncatchable by `builtins.tryEval`, so it was the one
   deliberate mistake in `examples/` that no test could hold. A shell script
   asserted on the exit status instead. `__toString` moved the report from
   Nix to floe, which is what made it testable; the script is gone.

2. **Kind naming.** _Answered: dotted strings, as the draft position had
   it,_ and the registry turned out not to be a separate thing. An output
   kind was a signature all along: `mkOutputKind` is gone, `mkSig` covers
   both, and the link-time collision check is `canonicalName`: one hole or
   provide name may not mean two signatures. See ADR 0003.

3. **Eval-time cycles between floes.** _Answered: derived, not declared, and
   left legal._ `wiringOne` and `wiringAll` are computed from headers before
   any body evaluates, so the eval graph and its strongly-connected
   components are known without running anything. Neither
   discouraged-by-convention nor rejected-by-linker: exposed as
   `link.cycles`, with every unit absent from one its own cache unit, and
   refusing them available as a _policy_ for a distribution that wants
   acyclic eval.

   Building that exposure then measured what the caching convenience was
   worth, and closed it: `examples/nixos`'s fleet is twenty-nine units in
   **one component of twenty-six**, because a namespace with an owner is a
   cycle through nearly everything. And twenty-nine floes are 3% of a whole
   NixOS evaluation anyway, so a perfect cache saves 74 ms of 2.2 s. Not
   worth building. ADR 0008 carries the numbers and the reasons the two
   decisions it records still stand without it.

   Rejecting them outright would still have traded a working property for
   that convenience: `examples/nixos` depends on mutual cycles, and a
   cycle's blast radius being one link is half of what floe does about
   NixOS's recursion problem. See ADR 0008, which also records the other
   thing this question decides: packages, not package sets, as inputs.

4. **Signature evolution.** _Answered, and it needed no versioning scheme._
   `link` checks that a provider's shape answers the requirer's: the
   provider must be a width-supertype, every field the requirer declared
   present and compatible. That _is_ the evolution rule: adding a field is
   compatible with every existing requirer, removing or retyping one is not,
   and the error names the field. A version number would restate it with
   less precision and need a compatibility rule of its own to mean anything.

   This question was right that it was needed before third-party floes
   exist, and right about why. Without the check, two definitions of one
   name linked cleanly and the consumer died on `attribute 'port' missing`
   several frames away, naming no floe, no field and no provider. See
   ADR 0007.

5. **`T.template` design.** _Closed: nothing has asked for it._ The residual
   case this named, data a provider cannot know in full and a consumer
   completes, went to two mechanisms that arrived for other reasons.
   `collects` covers the half where the consumer holds the knowledge and
   inverts the direction: a workload declares its own claim and the provider
   folds every claim, which is how `examples/nixos` provisions a database
   role per consumer with no template anywhere. A retrieval signature covers
   the half where the missing part is a value that does not exist yet.

   A provider-authored _string_ with named holes is what remains, and
   nothing has wanted one: not either example domain, and not forty floes
   across five labs in catallaxy. Closed on ADR 0003's rule, that machinery
   nothing exercises is worse than machinery that does not exist because it
   still costs vocabulary, and reopenable the moment something asks, with a
   use case attached.

**A sixth question this RFC did not ask**, and the one still open: **nothing
checks that a provider of a signature behaves like one.** Compatibility
checks shape, that `DATABASE.port` is a port, and nothing checks that what
answers `DATABASE` serves a database. NixOS RFC 0189, the closest living
relative to this design, attaches a `behaviorTest` to its contracts and
requires every provider to pass it.

`mkSig` briefly carried such a field, stored and never run, on the argument
that a VM test and a cluster to apply into have nothing in common so only a
distribution could run it. It is gone: nothing ran it, nothing could, and a
slot awaiting a design costs vocabulary while buying nothing, which is ADR
0003's rule applied to this document's own suggestion. The gap is recorded
here, where this repository keeps gaps, and closing it takes a distribution
that runs such a thing rather than a field for one.

## 8. Implementation plan

1. Prelude domain types plus `mkSig`, `mkOutputKind` (pure data).
2. `signatureOptions` / `optionsFromKinds` compilers to `mkOption`
   declarations.
3. `mkFloe` (per-floe `evalModules`, surface namespaces, `instantiate` with
   eager input pre-check).
4. `link` minus policies: resolve, fix, seal, collect, serialize (including
   rendered input docs).
5. Deferred tokens, output scan, deploy-edge and phase derivation.
6. `checkFloe` probes.
7. `mkHelmFloe` sugar (internal `chartValues` option, `out.k8s.helmRelease`
   projection).
8. Policy pass; Catallaxy kinds, signatures, policies.
9. Backends: ArgoCD slicer over `meta.cluster`; wire Terraform kind into the
   existing phased pipeline.
10. Later: `values.schema.json` to option-types converter for generating
    chart values schemas.

Milestone test: grafana wrapped as a floe providing OBSERVER, a downstream
app consuming it, with each error class in Motivation demonstrably failing
at eval.

## 9. Prior art

- MixML (Rossberg & Dreyer): mixin linking with type checking; source of the
  unit/link semantics.
- Backpack (Kilpatrick, Yang; GHC): signature merging, hole filling,
  checking units against holes without implementations; source of the
  layering where the linker is a separate mechanism from the language
  checking module contents.
- Racket contracts (Findler & Felleisen): boundary checking and blame,
  informing seal error design.
- NixOS module system: intra-floe implementation language; option types
  reused via schema compilation.
- Nixpkgs overlays: untyped fixpoint mixin linking in the wild.
- NixOS RFC 0189, "contracts" (ibizaman, 2025; from SelfHostBlocks): the
  closest living relative, and independent confirmation of §2: a consumer
  and a provider agree on typed `input`/`output` options and neither names
  the other. It reaches that from inside the global option tree, which is
  the substrate §6 rejects, and the two costs §6 predicts are its own
  unresolved questions: the end user must wire consumer→provider _and_
  provider→consumer by hand, because an `optionType` cannot reach the values
  of an instantiated contract; and the manual will not build, because
  `config.contracts` is not available where the type is needed. Its
  structural typing is what forecloses automatic resolution: with no name to
  key on, there is nothing for a linker to look up, so "exactly one
  provider" cannot be an error it detects. What it has and floe does not is
  `behaviorTest`: a generic VM test attached to the contract that every
  provider must instantiate and pass, so conformance covers behaviour and
  not only shape.
- Terraform unknown values: prior art for deferred propagation (open
  question 1).

# floe

A mixin module system for Nix: typed interfaces and linking between
components, layered over the NixOS module system rather than replacing it.
The vocabulary is borrowed from Haskell's Backpack and ML, which is why
[The Model](docs/model.md) explains most of it at once.

This file is a glossary and nothing else. Design decisions live in
[`docs/adr/`](docs/adr), the argument lives in
[RFC 0001](docs/rfcs/0001-floes.md), and the API lives in
[`docs/floe-api.md`](docs/floe-api.md).

## Language

### The unit model

**Floe**: A component with declared surfaces — inputs, requires, provides,
out — and a body of ordinary NixOS modules evaluated in its own isolated
`evalModules`. _Avoid_: module, component, package.

**Instantiation**: Applying a floe to the inputs a deployer chose, producing
a value that can be linked. A floe is instantiated, never enabled — there is
no `enable`, and a floe absent from a link is simply not there.

**Unit**: An instantiated floe under the name a link gives it. The name a
link keys on, and the name errors use. _Note_: Backpack calls the
_definition_ a unit; here it is the instance. The divergence is deliberate
and load-bearing, because a floe can be instantiated more than once in one
link.

**Body**: The list of NixOS modules a floe is implemented by. It reads
`config.floe.*` and nothing else — there is no ambient option tree and no
enclosing `config`.

### Interfaces

**Signature**: A named record schema for a value that crosses a floe
boundary. Resolution keys on its `name`, so two signatures sharing a name
are the same signature. _Avoid_: interface, contract, capability.

**Hole**: A signature a floe requires and does not implement. The arity is a
property of the hole rather than of the signature: `requires` is exactly
one, `requiresOptional` is zero or one, `collects` is every provider.
_Avoid_: dependency, slot.

**Provide**: What a floe answers, checked and restricted to its signature on
the way out.

**Sealing**: Restricting a provided value to the fields its signature
declares, by dropping the rest. A consumer sees the signature and never past
it. From ML's opaque ascription, and the reason a signature can be read as
the whole interface.

**Collected signature**: A signature some floe names in `collects` rather
than in `requires`, so every provider of it contributes. Used for additive
concerns; concerns with one answer stay plain holes. _Avoid_: facet,
contribution slot, aggregate. It is not a separate mechanism and should not
get a separate word.

**Deferred value**: A value that does not exist until after apply, carried
as a token. Reading one where a concrete value is required is an error at
eval naming the floe it came from; a token reaching output data becomes a
deploy edge and a later phase.

**Link-local**: A field whose meaning is confined to the link that produced
it — a Service address, a namespace, an API endpoint. Marked per field, and
refused when a consumer in another link would read it.

### Linking

**Link**: Resolving every hole against the providers present, tying the
result with `lib.fix`, sealing, and collecting output. One link is one
fixpoint. _Avoid_: graph, deployment, assembly.

**Scope**: An enclosing link whose provides a nested link may resolve
against, after its own units. How a wider context reaches a narrower one
without an ambient `config`.

**Binding**: A deployer saying which provider a particular hole means, when
there is more than one. The deployer's to make and not the author's, because
a floe does not know its peers' names.

**Phase**: How many deploy edges deep a unit sits, derived from deferred
tokens in output data. Nothing declares an ordering; nothing may.

### Output

**Output kind**: A dotted name plus a schema for one class of build product.
The _name_ is what collects fragments from different floes into one bucket;
the _schema_ is each floe's own, the way a NixOS module's options are its
own.

**Fragment**: One floe's contribution to an output kind — in the NixOS
examples, a piece of `config` shaped like the namespace that floe owns.

**Adapter**: The function a consumer writes to turn a link's output into
whatever its domain wants: NixOS modules, manifests, a plan. It lives with
the distribution, never in `lib/`.

### Domains

**Distribution**: A catalogue of signatures, output kinds and floes for one
domain, plus whatever sugar suits it. The library ships none — it depends on
nothing but `nixpkgs.lib` and knows no domain. Catallaxy is one; `examples/`
holds two small ones.

**Domain floe**: A floe that owns a namespace, collecting what its peers
claim and being the only thing in the link that emits it.
`examples/nixos/networking.nix` is the worked case. _Avoid_: domain module,
owner module.

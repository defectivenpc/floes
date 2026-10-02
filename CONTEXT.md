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

**Singleton floe**: A floe whose body writes fixed output paths rather than
keying them by the link's name for the instance, so two instances of it
would emit the same paths and merge silently. Declared by the author;
refused by the linker. _Avoid_: unique floe, single-instance.

**Body**: What a floe is implemented by — either `body`, a plain function of
its declared surfaces, or `modules`, ordinary NixOS modules for a floe that
wants the module system's merge inside itself. Either way it reads its
resolved holes and nothing else: there is no ambient option tree.

### Interfaces

**Signature**: A named schema for anything a floe commits to — a value it
exchanges with a peer, or a product it emits. Resolution keys on its `name`,
so two signatures sharing a name are the same signature. _Avoid_: interface,
contract, capability, output kind.

**Canonical name**: The name a hole or provide of a signature should be
called by. A name may not mean two different signatures in one link; a
signature may have more than one name, because a floe can hold a primary and
a replica of the same thing.

**Shape**: The `T` schema a signature is built from. Named for what it is
rather than for a direction, because a signature has none — the surface it
sits on is what makes it an input or an output.

**Hole**: A signature a floe requires and does not implement. The arity is a
property of the hole rather than of the signature: `requires` is exactly
one, `optional` is zero or one, `collects` is every provider. _Avoid_:
dependency, slot.

**Optional hole**: A hole a floe can do without, named in `optional`. It
resolves only when a deployer names the provider — by `.bind` or by the
link's `defaults` — and the body reads `null` otherwise. Presence alone
wires nothing, so adding a floe to a link never silently changes another
floe's output. The arity, not a second kind of hole.

**Compatibility**: Whether a provider's signature answers a requirer's. The
provider's shape must be a width-supertype of the requirer's: every field
the requirer declares is present and agrees, and extra fields on the
provider are what sealing drops. Checked from headers, before anything
evaluates. A concrete value satisfies a requirer that declared it deferred;
the reverse is refused. This is also the rule for signature evolution —
adding a field is compatible, removing or retyping one is not — which is why
there is no version number. An emitted signature has no requirer, so nothing
checks two floes that emit one name against each other, deliberately.
_Avoid_: structural typing, subsumption.

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

**Deferred value**: A value that does not exist until after apply — a
generated secret, an allocated address, a CA fingerprint. Typed
`T.deferred <inner>`, which says _when_ it exists and nothing about where.
Reading one where a concrete value is required is an error at eval naming
the floe it came from. The word is the programming-language one — a deferred
evaluation you can reference and have type-checked — rather than a
deployment-domain one. _Avoid_: runtime, lazy, unknown, promise.

**Retrieval signature**: An ordinary signature describing _where_ a deferred
value will be readable once it exists — a Secret and a key, a file and a
path. **A retrieval signature says where a value will be readable; a backend
implements how.** Declared by the provider, because the provider is what
creates the value, which is why one signature can be answered with a Secret
in Kubernetes and a file on NixOS. _Avoid_: mechanism — that is the
backend's implementation, which core deliberately never learns.

**Deferred token**: What a deferred value evaluates to: its source unit, its
retrieval signature's name, and a ref checked against that signature's
shape. Core records it and never looks inside.

**Deferred site**: A place a deferred token reached a floe's _output_, as
`{ unit; out; at; token; }` — a complete instruction to read one value and
write it at one path. Every site in a link is `link.deferredSites`; the
distinct retrievals a backend must implement are `link.deferredRetrievals`.
A provide carrying a token is not a site: only output is something a backend
substitutes into.

**Package**: A derivation or a store path, typed `T.package`, which is the
one way a built thing crosses a floe boundary. A floe takes the _packages_
it needs as ordinary inputs under a native NixOS option type, one at a time,
and never a whole package set: which nixpkgs, which overlays and which
system are the deployer's choice, and a package set can be neither hashed
for a cache key nor serialised.

**Derived field**: A field its provider computed by folding a collection.
The linker withholds it from any peer that contributes to that same
collection, because reading it there would be a cycle through the fold.
Marked per field, not per hole — the same hole is safe for every other field
on it.

### Linking

**Link**: Resolving every hole against the providers present, tying the
result with `lib.fix`, sealing, and collecting output. One link is one
fixpoint. _Avoid_: graph, deployment, assembly.

**Binding**: A deployer saying which provider a particular hole means, when
there is more than one. The deployer's to make and not the author's, because
a floe does not know its peers' names.

**Default**: The same decision made once for a whole link rather than per
consumer, so adding a second provider of something does not break every
consumer that has no opinion about which one it wants.

**Inclusion**: A floe whose body is a link, so a lab holding clusters is the
same mechanism as a cluster holding floes rather than a second one beside
it. It exports a declared subset of what its units provide, and may leave an
inner hole unfilled for the parent to fill — which is what makes one cluster
reusable across labs. Backpack's `include`. _Avoid_: scope, nesting,
sub-link.

**Export signature**: The signature an inclusion re-exports a provide under,
usually narrower than the one inside. How a value that means something only
in the link that produced it stays there: the boundary declares what crosses
and sealing drops the rest, rather than a field carrying a locality marking.
_Avoid_: local, uncrossable.

**Cycle**: A group of units whose holes resolve to each other. Derived, not
declared — the holes and provides are in the headers, so the linker knows
every cycle before a body evaluates. A cycle stays legal, because laziness
resolves it and the examples need it; naming it is what lets every unit
outside one be evaluated alone. _Avoid_: recursion, knot.

**Phase**: How many deploy edges deep a unit sits, derived from deferred
tokens in output data. Nothing declares an ordering; nothing may.

### Output

**Fragment**: One floe's contribution to an emitted signature — in the NixOS
examples, a piece of `config` shaped like the namespace that floe owns.

**Adapter**: The function a consumer writes to turn a link's output into
whatever its domain wants: NixOS modules, manifests, a plan. It lives with
the distribution, never in `lib/`.

### Domains

**Distribution**: A catalogue of signatures and floes for one domain, plus
whatever sugar suits it. The library ships none — it depends on nothing but
`nixpkgs.lib` and knows no domain. Catallaxy is one; `examples/` holds two
small ones.

**Domain floe**: A floe that owns a namespace, collecting what its peers
claim and being the only thing in the link that emits it.
`examples/nixos/networking.nix` is the worked case. _Avoid_: domain module,
owner module.

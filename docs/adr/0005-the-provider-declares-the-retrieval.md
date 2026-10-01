# The provider declares where a deferred value will be readable

`T.deferred` marked a value as not-yet-existing and produced a token
carrying `{ source; path; phase; }`. That bought the static safety it was
for — a floe cannot read a value that does not exist yet, and finds out at
`nix eval`. It bought nothing else: `path` was a label, `phase` was the
constant `"post-apply"`, and RFC 0001 §4.8's _"backends substitute token
sites between phases"_ was not implementable against it. A backend was
handed a name for the missing value and no way to find it.

A token now carries the **retrieval**: an ordinary signature describing
where the value will be readable, plus a ref checked against that
signature's shape.

```nix
caFingerprint = floe.mkDeferred SECRET_REF {
  namespace = "cert-manager"; name = "cluster-ca-tls"; key = "ca.crt";
};
```

Core checks the ref, records the signature's name, and never looks inside.
**A retrieval signature says where a value will be readable; a backend
implements how.**

## Why the provider and not the signature field

The mechanism could have lived on the type —
`T.deferred { via = "k8s.secret"; } T.str` — which is easier to find when
reading a signature. It would weld the signature to one domain.

The deciding case: `DATABASE.password` is answered in Kubernetes by a Secret
and on NixOS by a file. One signature, two mechanisms. Only the provider can
know which, because the provider is the thing that creates the value —
cert-manager knows it writes a Secret, postgres knows it writes a file. It
is the same reason `requires` names a signature and not a floe: the consumer
says what, the provider says how. `examples/` carries one of each so the
claim is exercised rather than asserted.

## Why core ships no substitution function

`floe.resolveRuntime output resolvedValues` was proposed and rejected. A
ConfigMap, a Secret, a resource annotation, a host file and an HTTP lookup
are five mechanisms for one job, and several may be correct for one value
depending on whether it is a secret. Picking one in core would choose for
every distribution at once, and core cannot know how a value is reified.

What core does instead is make the work discoverable:

```nix
link.deferredSites       # [{ unit; out; at; token; }]
link.deferredRetrievals  # the distinct retrievals needing resolvers
```

`at` is a list of keys rather than a dotted string, because output keys
contain dots — `floe.dev/ca-fingerprint` is a real Kubernetes annotation,
and a backend splitting on `.` would write to the wrong place.
`tests/examples.nix` performs a substitution in a test, which is the proof
that `deferredSites` is sufficient to write a backend against: if it were
not, the test would not work either.

## Why there is no check that a backend can resolve a link

A policy listing permitted retrievals was proposed and rejected: it states
what a _platform_ can do (this cluster can read Secrets), not what a
deployer has _wired up_ for a particular value, and the second is what fails
at apply time. A `link { resolvers = [ … ]; }` parameter was rejected for a
sharper reason — it is a claim about the backend, and core cannot verify
claims about the backend, so it would be ceremony that can be wrong.

The backend preflights: walk `deferredRetrievals`, compare against its own
resolver registry, refuse to start. That happens where the knowledge is, and
still before anything is applied.

## Consequences

`path` and `phase` are gone from the token. `path` was only ever the deploy
edge's `via` label, which is now the retrieval name — more useful, because
it says which resolver the edge needs. `phase` had one possible value and
nothing branched on it; apply order is _derived_, as `link.phases`, from the
topological depth of the deploy subgraph. It was a vestige of a design where
ordering might have been declared.

A provide carrying a token is not a site. Only output is something a backend
substitutes into, and the NixOS example has **zero** sites as a result —
nothing there puts the secret in config, because `DATABASE` offers
`passwordFile` beside `password` and a systemd unit takes the path. That is
the correct shape, and `examples/nixos/broken.nix` is where putting the
value itself into config is demonstrated as the mistake. The two examples
therefore show both halves: Kubernetes renders a value into a manifest and
needs a backend; NixOS hands over a path and needs nobody.

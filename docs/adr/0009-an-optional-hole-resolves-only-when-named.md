# An optional hole resolves only when a deployer names the provider

`docs/adr/0003` deleted `requiresOptional` as "an arity nobody used… two
designs, no users". Catallaxy had 26 live call sites across seven floes:
grafana's OIDC, a collector's three telemetry backends, argocd, forgejo,
harbor. The same mistake as `scope`: "no caller in this repository" is not
"no caller".

So it is back, as `optional`, a third arity beside exactly-one and
every-provider. The rename is mechanical. **The semantics changed, and that
is the decision this records.**

An optional hole used to resolve to whatever single provider happened to be
in the link. It now resolves only when a deployer names one, by `.bind` or
by the link's `defaults`, and a link holding an unnamed provider for an
optional hole is an error naming the candidate.

## Why presence is not consent

Wiring an optional hole involves three facts, and the old rule collapsed
them into two. A deployer putting kanidm in a cluster is one decision.
Putting forgejo there is another. Whether forgejo should use kanidm for OIDC
is a **third**, and nothing about the first two answers it.

Under the old rule a cluster holding kanidm wired OIDC into forgejo, harbor
and everything else that asked. A deployer who wanted kanidm for internal
auth and local accounts for forgejo had no way to say so, and no indication
it had happened.

The property the new rule buys is worth naming, because it is the one that
makes a large configuration readable: **adding a floe to a link never
changes another floe's output.** `requires` has always had it, for free, by
erroring on a second provider. This is that property for a hole that may be
absent.

That the property is worth something is not a guess. Catallaxy's homelab
carried a prose paragraph in its header explaining that Grafana's OIDC hole
was unwired on purpose: the author had to write, in English, that an absence
was intended, because the mechanism could not express it. Under this rule,
the absence of a line means intended non-wiring, and wiring is the
statement.

## What it costs

A line per optional signature per link, which the error message dictates
verbatim. Measured on the port: catallaxy's eleven consumer-holes collapsed
to **four** `defaults` entries in the cluster that holds everything, because
`defaults` is per signature rather than per consumer. One line covered
forgejo, harbor, hello, argocd and grafana's OIDC together.

It also needed a new user-facing option in that distribution,
`lab.clusters.<c>.defaults`, which is where a deployer now makes the third
decision. A distribution that wants the old behaviour can compute those
entries itself, since "the sole provider in this link, if there is one" is
four lines, and the difference is that it would then be _that
distribution's_ documented rule rather than something core did to every
consumer without saying so.

## The alternatives

**Leave it deleted.** Rejected: the 26 call sites are real, and the shape
they need, "use this if the link has one", has no spelling in terms of the
other two arities. Emulating it with `collects` and a body-side arity check
loses `.bind` and `defaults`, since a collection takes every provider and
has nothing to choose.

**Keep automatic resolution.** Rejected for the reason above, and for a
second one: it makes the link non-monotonic in a way nothing reports. The
failure mode is a configuration that does something different after an
unrelated addition, with no error anywhere.

**A silent no-op when unnamed.** Rejected as the worst of the three. A
deployer who adds kanidm and gets no OIDC needs to be told why, and an error
naming the candidate is the only version of this that teaches the rule
rather than hiding it.

## Consequences

Resolved values land in `requires` beside the exactly-one holes, as the
value or as `null`, so a body wanting "the thing if it is there" reads one
place. A hole name on both surfaces is refused, since they merge into one
attrset and one of them would vanish with nothing saying so.

Migration is not mechanical and `docs/migrating.md` leads with that. A lab
that got OIDC and telemetry backends by presence will error until each link
says what it meant, which is the intended outcome and will read as a
regression to anyone who has not read this.

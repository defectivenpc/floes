# The NixOS examples give namespaces an owner

NixOS modules scale badly because one global option tree has no owners: any
module may write `networking.firewall.allowedTCPPorts`, the merge is a list
union nobody chose, and two services claiming one port is not an event. The
question floe had never been tested against is whether `collects` can
replace that — can a service contribute to a namespace it does not own,
without writing a global option?

`examples/nixos` answers it by giving one namespace an owner:
`networking.nix` collects a `PORT_CLAIM` from its peers and is the only floe
in the link that emits `networking`.

## Considered options

The alternative was to leave stock NixOS underneath and use floes only for
coarse services, with signatures appearing just where a floe hands config
back. Smaller change, easier to propose to nixpkgs, and it is what a long
design conversation on this recommended.

Rejected for the examples because it tests nothing. With the global option
tree still underneath, the un-cacheable global fixpoint — the thing that
makes a one-line edit re-evaluate a whole configuration — survives
untouched. Giving namespaces owners is the version that can fail, and the
examples are contrived and disposable, which makes them the cheapest place
to find out.

## What the probe found

It works, and it needed no new primitive — `mkSig`, `requires`, `collects`
and `mkOutputKind` as they already were.

It also found that the framing was too broad. **Only namespaces whose merge
carries policy need an owner.** `networking.firewall.allowedTCPPorts` is a
list whose merge is a decision, so it needs one. `systemd.services.<name>`
and `users.users.<name>` are attrsets keyed by a unique name, disjoint by
construction, and several floes write them with no possibility of collision.
The examples do exactly that, and a test pins the distinction. Requiring an
owner for every namespace would have been ceremony for nothing.

## Consequences

This is a claim about the examples, not a commitment in `lib/`. The one
library change that came out of it is `singleton` on `mkFloe`, and that came
from the multi-instance work rather than from this.

`docs/adr/0002` records the other half: wrapping existing nixpkgs modules
would have made adoption far easier, and is about 200× more expensive than
writing the floe by hand.

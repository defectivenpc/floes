# The NixOS examples target the substrate, not a service layer

NixOS modules scale badly because there is one global option tree and any
module may write any part of it. The question floe has never been tested
against is whether `collects` can replace that — whether a service can
contribute to a namespace it does not own without writing a global option.
`examples/nixos` answers it by giving one namespace an owner: a floe that
collects a signature from its peers and is the only thing that emits
`networking.firewall`.

## Considered options

The alternative was a **service layer**: leave stock NixOS as the substrate,
wrap coarse services in floes, and let signatures appear only where a floe
hands config back. It is a smaller change and an easier thing to propose to
nixpkgs, and it is what a long design conversation on this recommended.

It was rejected for the examples because it does not test anything. Under a
service layer the global option tree is still underneath everything, so the
un-cacheable global fixpoint — the thing that makes a one-line edit
re-evaluate a whole configuration — survives untouched. The substrate
version is the one that can fail, and the examples are contrived and
disposable, which makes them the cheapest place to find out.

## Consequences

This is a claim about the examples and **not** a commitment in `lib/`. The
library is unchanged by it: the probe uses `mkSig`, `requires`, `collects`
and `mkOutputKind` as they already are, and adds no primitive.

If the probe reads badly — if giving a namespace an owner takes more
ceremony than `networking.firewall.allowedTCPPorts = [ 80 ]` is worth — that
is the answer, and the service-layer framing is where to go next. A
line-count assertion over the deployer-facing block keeps that question
honest, because it is the one a mechanism demo will otherwise never ask.

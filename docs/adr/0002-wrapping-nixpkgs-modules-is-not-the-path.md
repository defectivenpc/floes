# Wrapping nixpkgs modules is not the adoption path

Adopting floe for NixOS would be far easier if a floe could host an existing
nixpkgs service module unchanged. It can: a shim of about twenty-five
declarations lets nginx, dnsmasq and prometheus evaluate inside a floe's
isolated `evalModules` and emit their real units. It costs about **77 ms and
26 MB per distinct module**, against **0.34 ms** for a hand-written floe of
comparable weight — roughly 200×. We are not pursuing it, and not optimising
it.

## Why not optimise it

Some of that cost is recoverable: every floe currently re-declares its own
shim and re-imports `misc/ids.nix`. Sharing those would help by an
unmeasured amount.

The decision was to stop anyway, because floes are already fast enough
hand-written — twenty-nine of them add 39 MB and no measurable time to a
stock NixOS evaluation — and a wrapped floe is not encapsulated in any case.
The wrapped module writes whatever it likes into the namespaces the shim
catches; `examples/wrapped` found nginx writing `boot.kernelModules`. Making
wrapping fast would produce a fast way to get floes without the property
floes exist for.

## What replaces it

The spike's useful finding, recorded in `examples/wrapped/README.md`: the
shim catches _writes_ generically, but a module's _reads_ each need a real
value, and those reads are exactly the dependencies nixpkgs never declared.
postgresql reads `config.system.stateVersion`; sshd reads
`config.programs.ssh.*`.

So the discovery loop is a tool for **extracting a nixpkgs module's implicit
interface** — run it, and every read it fails on is an undeclared
dependency. That is a migration path, and it does not require the module to
run inside a floe at all. It is not built.

## Consequences

A floe that wraps a nixpkgs singleton module is also single-instance by
construction, because it emits that module's fixed option paths. Not
wrapping is therefore what makes multi-instance possible at all —
`examples/nixos/postgres.nix` gets two Postgres servers on one host
precisely because it does not use `services.postgresql`. The cost is that
the floe is the nixpkgs module's job done again, which is the ~350
author-side lines the README accounts for.

`singleton` was added to `mkFloe` off the back of this: a floe that does
write fixed paths declares it, and the linker refuses a second instance.

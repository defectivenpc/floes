# Wrapping real nixpkgs modules

A spike, kept because its answer is useful and not because anyone should
build on it. The question: could a floe host an existing nixpkgs service
module unchanged, so adopting floe would not mean rewriting nixpkgs?

```bash
nix eval --impure --json --expr 'import ./examples/wrapped/spike.nix { k = 3; }'
```

Not a flake check, and not optimised. See
[ADR 0002](../../docs/adr/0002-wrapping-nixpkgs-modules-is-not-the-path.md).

## It works

A real nixpkgs service module does evaluate inside a floe's isolated
`evalModules`, behind a shim of about twenty-five declarations. nginx (1685
lines), dnsmasq and prometheus each produce their genuine systemd unit, user
and group. [`shim.nix`](shim.nix) is the whole of it.

Two things learned about how:

**`types.anything`, never `types.raw`.** A `raw` catch-all captures
`{ _type = "if"; … }` — the unmerged `mkIf` wrappers nixpkgs modules are
written with. A shim built on `raw` appears to work and yields garbage.

**Writes are generic; reads are not.** One catch-all serves any module that
_writes_ a namespace. A module that _reads_ one needs a real value, and
choosing it is a semantic decision. postgresql reads
`config.system.stateVersion`; sshd reads `config.programs.ssh.*`; both load
fine and then fail when their output is forced.

The audit works too, and immediately found something: nginx writes
`boot.kernelModules = [ "tls" ]`, a namespace a web server has no business
owning.

## It costs too much

Marginal cost per **distinct** wrapped module, forced to what a floe's `out`
would carry:

|                          | cpu        | allocated  |
| ------------------------ | ---------- | ---------- |
| nixpkgs import alone     | 0.020 s    | 0 MB       |
| one wrapped module       | 0.205 s    | 110 MB     |
| three wrapped modules    | 0.358 s    | 162 MB     |
| **marginal, per module** | **~77 ms** | **~26 MB** |

Against a hand-written floe at comparable weight — 0.34 ms and about 0.3 MB
— that is roughly **200×**. At fifty enabled services it is a few seconds
and over a gigabyte; the whole of `examples/nixos`, twenty-nine hand-written
floes, adds 39 MB and no measurable time to a stock NixOS evaluation.

Each floe re-declares its own shim and re-imports `misc/ids.nix`, so sharing
that would recover some of it. That mitigation is untested: the decision was
to stop here rather than optimise something already ruled out.

## The part worth keeping

The reads a wrapped module makes are exactly its undeclared dependencies —
the things that, in a floe, would be `inputs` or a signature. The discovery
loop that produced `shim.nix` is therefore a way to **extract a nixpkgs
module's implicit interface**: run it, and every read it fails on is a
dependency nobody wrote down.

That is a migration story, and a better one than wrapping. It does not need
the module to run inside a floe at all — only to be interrogated about what
it reaches for.

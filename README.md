# floe

**Typed interfaces and mixin linking for Nix modules.** A floe is a unit
with declared surfaces — inputs, requires, provides, out — and a body of
ordinary NixOS modules. What a floe needs, it names by _signature_; the
linker finds whatever provides it, checks the value against that signature,
and hides everything else.

The model is Haskell's Backpack — signatures, holes, mixin linking,
instantiation — applied to the NixOS module system, with sealing from ML.
[RFC 0001](docs/rfcs/0001-floes.md) is the design;
[The Model](docs/model.md) says where the words come from.

```nix
floe.mkFloe {
  name = "grafana";
  summary = "Grafana, wired to whatever observability backend the link finds.";

  inputs.adminUser = lib.mkOption { type = lib.types.str; };

  requires.ingress = sigs.INGRESS;      # exactly one provider
  collects.dashboards = sigs.DASHBOARD; # every provider, keyed by unit
  provides.observer = sigs.OBSERVER;

  body = { inputs, requires, collects, ... }: { provides.observer = …; };
}
```

Nothing there names the thing that answers `INGRESS`. Exactly one unit in
the link provides it, checked at eval, and a second is an error naming both.

## Why

The NixOS module system solves intra-component composition — merging partial
configuration from many files — extremely well, and inter-component
interfaces poorly: one global option tree, merge-everything semantics, no
hiding. Any module may write any option, and nothing says what a component
promises or requires.

Floe adds the missing layer without touching the module system. Each floe
wraps its own isolated `evalModules`, so merge stays where it works. Between
floes there are signatures, exactly-one resolution, and sealing — so a value
crossing a boundary has a declared shape, and a consumer sees only the
fields the signature names.

Errors that used to surface at deploy time surface at `nix eval`:
referencing something a component never promised, providing a value of the
wrong shape, a missing or ambiguous implementation, or using a value that
does not exist until after apply.

## The surfaces

| Declaration | Arity                                         |
| ----------- | --------------------------------------------- |
| `requires`  | exactly one provider; zero or two is an error |
| `collects`  | every provider, keyed by unit; may be empty   |
| `provides`  | what it answers, sealed to the signature      |
| `out`       | what it emits, collected by signature name    |

Arity is a property of the hole, not of the signature: a second provider
makes every `requires` of it ambiguous. The deployer says which a given
consumer means, per consumer or once for the link:

```nix
(floes.harbor { }).bind { issuance = "internal-ca"; }

floe.link { units = { … }; defaults.X509_ISSUANCE = "internal-ca"; }
```

[The mkFloe API](docs/floe-api.md) is the reference.

## Use it

```nix
{
  inputs.floe.url = "github:defectivenpc/floes";

  outputs = { nixpkgs, floe, ... }:
    let
      lib = nixpkgs.lib;
      f = floe.mkFloeLib lib;   # one nixpkgs, yours
    in
    f.link { units = { /* ... */ }; };
}
```

`mkFloeLib` takes your `lib` so that floe's nixpkgs pin decides nothing
downstream. `floe.lib` is the same library against this flake's own pin, for
poking at it without a nixpkgs to hand.

The library depends on nothing but `nixpkgs.lib`. It knows nothing about
Kubernetes, or about any particular domain — a _distribution_ supplies the
signatures, and `examples/` holds two small worked ones.

## Develop

```bash
nix flake check    # the suite, and formatting
nix fmt
```

## Prior art

Extracted from [catallaxy](https://github.com/defectivenpc/catallaxy), where
it was `lib/floe-core` and remains the layer the platform is built on. That
repository's history has the rest, including two earlier implementations
that preceded this one.

## License

[MIT](LICENSE)

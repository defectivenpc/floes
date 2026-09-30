# Per-floe evaluation cost at scale.
#
# A chain of n floes: floe i requires floe i-1's provide and folds it into its
# own, so the whole link is one connected fixpoint rather than n independent
# evaluations the linker never has to tie together. Forced with `deepSeq`, so
# every provide, out, edge and phase is paid for.
#
# `withInputs` is the interesting axis: a floe declaring inputs pays a *second*
# `lib.evalModules` at instantiate time, in `floe.nix`'s `checkInputs`. Almost
# every real floe has inputs, so `true` is the realistic number and `false`
# isolates how much of the cost that second evaluation is.
#
# `chain` separates two confounds. With it, each floe folds its predecessor's
# value into its own, which is realistic but builds strings of growing length —
# quadratic in total characters, independent of anything the linker does.
# Without it, no floe requires anything, so what is left is the per-floe
# evaluation plus whatever the linker costs to resolve and collect n units.
{
  lib ? import <nixpkgs/lib>,
  n,
  withInputs ? true,
  chain ? true,
  # Whether a body actually folds its predecessor's value into its own. `chain`
  # decides how many holes the linker resolves; `fold` decides whether the values
  # flowing through them grow.
  #
  # Defaults to `false`, because `true` measures a quadratic this benchmark
  # creates rather than anything floe does: with it, floe i's value contains every
  # predecessor's label, so total characters are O(n²). Memory at n = 500 → 4000
  # goes 94 → 278 → 945 → 3514 MB with the fold and 50 → 100 → 199 → 399 MB
  # without it. The second is floe's actual scaling; the first is string
  # concatenation.
  #
  # It is still worth having as an axis: a 1000-deep chain where every floe
  # accumulates its predecessors is not a real link — real ones are shallow and
  # wide — but the flag is what proves the quadratic belongs to the benchmark.
  fold ? false,

  # How heavy each floe's *body* is: how many fields its output schema declares
  # and its body computes. `weight = 1` is the floor; the example floes in
  # `examples/nixos` sit around 15, which is a nested `T.record` and a
  # systemd-unit-shaped fragment. Extrapolating from `weight = 1` understates a
  # real floe, which is what this exists to fix.
  #
  # It does *not* scale the input count: declaring an input costs about 0.013ms
  # and 5MB per floe on its own (see `inputCount`), so tying the two together
  # made every figure pessimistic by however many inputs the weight implied.
  weight ? 1,

  # How many inputs each floe declares, all of them read. Three is what the
  # example floes average; the cost is linear in it.
  inputCount ? 3,

  # Which body form. `modules` runs the floe's module list in its own
  # `lib.evalModules`, which is what buys the module system's merge inside a floe
  # — and what makes hosting an existing NixOS module possible at all. `body` is
  # a plain function and pays none of it.
  #
  # Neither form avoids `checkInputs` (`lib/floe.nix`), a *separate*
  # `evalModules` that runs at instantiate time purely to type-check what the
  # deployer passed. `inputCount` measures that one, and it is the larger of the
  # two at a realistic input count.
  form ? "modules",
}:

let
  floe = import ../lib { inherit lib; };
  T = floe.T;

  # One signature per link in the chain: resolution is by name, so a shared
  # signature would make every floe a provider of one thing and fail arity.
  sigOf =
    i:
    floe.mkSig {
      name = "CHAIN_${toString i}";
      canonicalName = "chain${toString i}";
      description = "Benchmark signature for chain position ${toString i}.";
      shape = T.record { v = T.str; };
    };

  # A narrow, nested output schema rather than `attrsOf any`: checking a real
  # `T.record` tree is work a real floe pays for, and `attrsOf any` skips it.
  fieldNames = lib.genList (k: "f${toString k}") weight;
  inputNames = lib.genList (k: "i${toString k}") inputCount;

  kind = floe.mkSig {
    name = "bench.out";
    canonicalName = "bench";
    description = "Benchmark output signature.";
    shape = T.record (
      lib.genAttrs fieldNames (
        _:
        T.record {
          name = T.str;
          port = T.port;
          enable = T.bool;
          tags = T.listOf T.str;
        }
      )
    );
  };

  mkUnit =
    i:
    let
      # Reading an input is what forces `checkInputs`, and so what makes the
      # second `evalModules` per floe actually get paid for.
      # Every declared input, concatenated. A real floe reads the inputs it
      # declares; reading one and letting `checkInputs`' own `deepSeq` force the
      # rest would measure the deepSeq instead of the floe.
      readAll = inputs: lib.concatStringsSep "-" (lib.attrValues inputs);

      mkV =
        self: requires:
        if !chain || i == 0 then
          self
        else if fold then
          "${requires."chain${toString (i - 1)}".v}.${self}"
        else
          builtins.seq requires."chain${toString (i - 1)}".v self;

      outFor =
        v:
        lib.genAttrs fieldNames (n: {
          name = "${v}-${n}";
          port = 1024 + i;
          enable = true;
          tags = [
            n
            "bench"
          ];
        });
    in
    (floe.mkFloe {
      name = "bench-${toString i}";
      summary = "Benchmark floe at chain position ${toString i}.";

      inputs = lib.optionalAttrs withInputs (
        lib.genAttrs inputNames (
          n:
          lib.mkOption {
            type = lib.types.str;
            default = "u${toString i}-${n}";
            description = "Exists so the floe pays for declaring and checking an input.";
          }
        )
      );

      requires = lib.optionalAttrs (chain && i > 0) { "chain${toString (i - 1)}" = sigOf (i - 1); };
      provides."chain${toString i}" = sigOf i;
      out.bench = kind;

      modules = lib.optional (form == "modules") (
        { config, ... }:
        let
          self = if withInputs then readAll config.floe.inputs else toString i;
          v = mkV self config.floe.requires;
        in
        {
          config.floe.provides."chain${toString i}" = { inherit v; };
          config.floe.out.bench = outFor v;
        }
      );

      body =
        if form != "body" then
          null
        else
          {
            inputs,
            requires,
            ...
          }:
          let
            self = if withInputs then readAll inputs else toString i;
            v = mkV self requires;
          in
          {
            provides."chain${toString i}" = { inherit v; };
            out.bench = outFor v;
          };
    }).instantiate
      { };

  result = floe.link {
    units = lib.listToAttrs (
      map (i: lib.nameValuePair "f${toString i}" (mkUnit i)) (lib.range 0 (n - 1))
    );
  };
in
builtins.deepSeq result n

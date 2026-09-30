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
  # Whether a body actually folds its predecessor's value in. `chain` decides
  # how many holes the linker resolves; `fold` decides whether the values
  # flowing through them grow. Splitting them separates a cost in the linker
  # from a cost in the benchmark's own string building.
  fold ? true,

  # How heavy each floe's body is. `weight = 1` is the floor: one input, one
  # string. The example floes in `examples/nixos` sit around `weight = 15` —
  # several inputs, a nested `T.record` output schema, a systemd-unit-shaped
  # fragment. Anything extrapolated from `weight = 1` understates a real floe,
  # which is the flaw this parameter exists to fix.
  weight ? 1,

  # Which body form. `modules` pays a whole `lib.evalModules` per floe for the
  # module system's merge; `body` is a plain function and pays none of it. Most
  # floes never merge anything, so this is the difference between the two.
  #
  # Measured at ~30% of a floe's cost at realistic weight, not the whole of it,
  # because `checkInputs` in `lib/floe.nix` still runs an `evalModules` of its
  # own to validate inputs whichever form the body took. That is the next thing
  # to cut if anyone needs it cut.
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
        lib.genAttrs fieldNames (
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
          self = if withInputs then config.floe.inputs.${lib.head fieldNames} else toString i;
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
            self = if withInputs then inputs.${lib.head fieldNames} else toString i;
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

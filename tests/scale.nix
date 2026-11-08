# Pins `bench/scale/gen.nix` at a size the suite can afford, so the generator
# cannot rot between benchmark runs. The property that matters is that the
# floe distribution and the NixOS twin compute the same output: without it a
# cost difference between them could be a difference of workload.
{ lib, floe }:

let
  gen = args: import ../bench/scale/gen.nix ({ inherit lib floe; catalogue = 20; n = 10; } // args);
  agree = args: let g = gen args; in g.floeOut == g.twinOut;
  fails = expr: !(builtins.tryEval (builtins.deepSeq expr "evaluated")).success;
in
lib.runTests {
  testScaleTwinAgrees = {
    expr = agree { };
    expected = true;
  };

  # Every unit in every collection, and a chain deep enough to cross layers.
  testScaleTwinAgreesAtMaxFanOut = {
    expr = agree {
      fanOut = 10;
      depth = 5;
    };
    expected = true;
  };

  # Nesting is floe-only, and must not change what is emitted.
  testScaleTwinAgreesNested = {
    expr = agree { nest = 3; };
    expected = true;
  };

  # Through the adapter into a NixOS core, the whole of Q1(b)'s path.
  testScaleAdapterAgrees = {
    expr = let g = gen { fanOut = 10; }; in g.floeAdapted == g.twinOut;
    expected = true;
  };

  testScaleNonTrivial = {
    expr = lib.length (lib.attrNames (gen { }).floeOut.services) > 0;
    expected = true;
  };

  testScaleFloeFaultsAreRefused = {
    expr = map (f: fails (gen { fault = f; }).floeOut) [
      "missing"
      "retype"
      "derived"
      "singleton"
    ];
    expected = [
      true
      true
      true
      true
    ];
  };

  # Only the catchable one: the twin's missing provider is Nix's own
  # "attribute missing", which `tryEval` cannot catch. `run.sh` measures it.
  testScaleTwinRetypeFails = {
    expr = fails (gen { fault = "retype"; }).twinOut;
    expected = true;
  };
}

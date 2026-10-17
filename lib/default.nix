# Floe core: mixin linking over `lib.evalModules` (RFC 0001).
# Generic library: Contains no Kubernetes, signatures, kinds and policies belong to a distribution.
{ lib }:

let
  types = import ./types.nix { inherit lib; };
  interfaces = import ./interfaces.nix { inherit lib types; };
  floe = import ./floe.nix { inherit lib types; };
  refusals = import ./refusals.nix { inherit lib types; };
  distribution = import ./distribution.nix { inherit lib types; };
  link = import ./link.nix {
    inherit
      lib
      types
      interfaces
      refusals
      ;
    floeLib = floe;
  };
in
{
  T = types;
  inherit (types) checkValue conformValue isDeferredToken;
  inherit (distribution) mkDistribution;
  inherit (interfaces)
    mkSig
    project
    narrows
    renderInputs
    ;
  inherit (floe)
    mkFloe
    isInstance
    instanceType
    ;
  inherit (link) link candidatesFor;
}

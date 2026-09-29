# Floe core: mixin linking over `lib.evalModules` (RFC 0001).
# Generic library: Contains no Kubernetes, signatures, kinds and policies belong to a distribution.
{ lib }:

let
  types = import ./types.nix { inherit lib; };
  interfaces = import ./interfaces.nix { inherit lib types; };
  floe = import ./floe.nix { inherit lib types; };
  link = import ./link.nix {
    inherit lib types interfaces;
    floeLib = floe;
  };
in
{
  T = types;
  inherit (types) checkValue isDeferredToken;
  inherit (interfaces)
    mkSig
    mkOutputKind
    isUncrossable
    renderInputs
    ;
  inherit (floe) mkFloe isInstance instanceType;
  inherit (link) link candidatesFor;
}

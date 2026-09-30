# The two worked examples, against one library.
#
# Neither is for reuse. Catallaxy has its own Kubernetes distribution and
# nixpkgs has its own module system; these exist so that floe is developed
# against two domains instead of one, and so that a reader can see what the
# library looks like in use without adopting anything.
#
#   nixos   the probe: fine-grained units, a namespace with an owner,
#           services contributing to it. `docs/adr/0001` says why.
#   k8s     the contrast: coarse units, a resolution chain, loose output.
#           The shape floe was originally designed against.
{ lib, floe }:

{
  nixos = import ./nixos { inherit lib floe; };
  k8s = import ./k8s { inherit lib floe; };
}

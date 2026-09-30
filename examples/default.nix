# The worked examples, against one library.
#
# Neither is for reuse. Catallaxy has its own Kubernetes distribution and
# nixpkgs has its own module system; these exist so that floe is developed
# against more than one domain, and so that a reader can see what the
# library looks like in use without adopting anything.
#
#   nixos   the probe: fine-grained units, a namespace with an owner, services
#           contributing to it, two databases on one host. Two links from one
#           set of floes — five units to read, twenty-nine to measure.
#   k8s     the contrast: coarse units, a resolution chain, loose output. The
#           shape floe was originally designed against.
#
# `wrapped/` is a third, and not a distribution: a spike answering "could floes
# just wrap nixpkgs modules?". It is not imported here because it needs `pkgs`
# and costs ~77ms per module. See `docs/adr/0002`.
{ lib, floe }:

{
  nixos = import ./nixos { inherit lib floe; };
  k8s = import ./k8s { inherit lib floe; };
}

# What the NixOS floes emit, and why each one narrows the shape itself.
#
# A signature is a dotted `name` plus a `shape`. The *name* is what collects
# fragments from different floes into one bucket; the *shape* has no reason to be
# shared, and here it must not be — `postgres` emits `systemd` and `users`,
# `networking` emits `networking`, and they have nothing in common.
#
# So each floe narrows the shape itself, the way a NixOS module declares its own
# options. `link` checks each floe's `out` against that floe's own signature and
# groups by `name`, which is what makes this work with no library support.
{ floe }:

{
  nixosConfig =
    shape:
    floe.mkSig {
      name = "nixos.config";
      canonicalName = "nixosConfig";
      description = "A fragment of NixOS `config`, merged by the adapter.";
      inherit shape;
    };
}

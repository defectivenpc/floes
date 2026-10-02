# What the NixOS floes emit, and why each one narrows its own fields.
#
# A signature is a dotted `name` plus its `fields`. The *name* is what collects
# fragments from different floes into one bucket; the *fields* have no reason to
# be shared, and here they must not be — `postgres` emits `systemd` and `users`,
# `networking` emits `networking`, and they have nothing in common.
#
# So each floe narrows them itself, the way a NixOS module declares its own
# options. `link` checks each floe's `out` against that floe's own signature and
# groups by `name`, which is what makes this work with no library support.
{ floe }:

{
  nixosConfig =
    fields:
    floe.mkSig {
      name = "nixos.config";
      canonicalName = "nixosConfig";
      description = "A fragment of NixOS `config`, merged by the adapter.";
      inherit fields;
    };
}

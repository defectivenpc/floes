# The one output kind this example has, and the reason it takes a schema.
#
# An output kind is a dotted name plus a schema. The *name* is what collects
# fragments from different floes into one bucket; the *schema* has no reason to
# be shared, and here it must not be — postgres emits `services.postgresql` and
# the firewall emits `networking.firewall`, which have nothing in common.
#
# So each floe narrows the schema itself, the way a NixOS module declares its
# own options. Same name, different schema, and `link` checks each floe's
# fragment against its own: `lib/link.nix` checks `out` per unit against that
# unit's kind, and groups by `kind.name`. No library change was needed for
# this; it just had not been written down.
{ floe }:

{
  nixosConfig =
    schema:
    floe.mkOutputKind {
      name = "nixos.config";
      description = "A fragment of NixOS `config`, merged by the adapter.";
      inherit schema;
    };
}

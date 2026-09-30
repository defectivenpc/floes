# The owner of `networking.*`.
#
# This floe is the point of the example. In stock NixOS any module may write
# `networking.firewall.allowedTCPPorts`; the merge is a list union nobody
# chose, and two services claiming one port concatenate and whichever unit
# binds first wins at runtime.
#
# Here the namespace has an owner. Services do not write it. They provide a
# PORT_CLAIM, this floe collects every one of them, and it is the only thing in
# the link that emits `networking`. The merge policy is therefore *this file's*
# decision, and it can be stricter or more intelligent than a union.
{
  lib,
  floe,
  sigs,
  kinds,
}:

let
  T = floe.T;
in
floe.mkFloe {
  name = "networking";
  summary = "A linux machine's networking.*: identity, and the ports its peers claim.";

  # Writes fixed paths, so two of it would silently merge into one.
  singleton = true;

  inputs = {
    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Short host name.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      description = "DNS domain this machine sits under.";
    };
    externalInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Interface claimed ports are opened on.";
    };
  };

  collects.claims = sigs.PORT_CLAIM;
  provides.network = sigs.NETWORK;

  out.nixosConfig = kinds.nixosConfig (
    T.record {
      networking = T.record {
        hostName = T.str;
        domain = T.dnsName;
        firewall = T.record {
          enable = T.bool;
          interfaces = T.attrsOf (T.record { allowedTCPPorts = T.listOf T.port; });
        };
      };
    }
  );

  modules = [
    (
      { config, ... }:
      let
        # Keyed by the unit that claimed it, which is what makes a useful error
        # possible: the linker already knows who, so the message can say who.
        claims = config.floe.collects.claims;

        flat = lib.concatMap (
          u:
          map (p: {
            port = p;
            by = u;
          }) claims.${u}.tcp
        ) (lib.attrNames claims);

        collisions = lib.filterAttrs (_: cs: lib.length cs > 1) (lib.groupBy (c: toString c.port) flat);

        openPorts =
          if collisions == { } then
            lib.sort (a: b: a < b) (lib.unique (map (c: c.port) flat))
          else
            throw (
              "networking: two services claim the same port.\n"
              + lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  port: cs: "  - ${port}: claimed by ${lib.concatMapStringsSep ", " (c: "'${c.by}'") cs}"
                ) collisions
              )
              + "\n\nOnly one process can bind a port. In stock NixOS both "
              + "definitions would merge into one list and the collision would "
              + "surface when the second unit failed to start."
            );
      in
      {
        config.floe.provides.network = {
          inherit (config.floe.inputs)
            hostName
            domain
            externalInterface
            ;
          inherit openPorts;
        };

        config.floe.out.nixosConfig.networking = {
          inherit (config.floe.inputs) hostName domain;
          firewall = {
            enable = true;
            # Per interface rather than the global list, which is the honest
            # translation of "opened on the external interface" and the reason
            # this floe has an `externalInterface` input at all.
            interfaces.${config.floe.inputs.externalInterface}.allowedTCPPorts = openPorts;
          };
        };
      }
    )
  ];
}

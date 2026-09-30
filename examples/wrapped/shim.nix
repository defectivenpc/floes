# What a floe must declare to host a real, unmodified nixpkgs service module.
#
# Discovered by iteration, not designed: evaluate the module, read the error, add
# what it asks for, repeat. `spike.nix` reproduces that and the measurements.
#
# Two things about this file are the actual findings.
#
# **`types.anything`, never `types.raw`.** A `raw` catch-all captures
# `{ _type = "if"; condition = …; }` — the unmerged `mkIf` wrappers nixpkgs
# modules are written with. `anything` merges them properly. A shim built on
# `raw` appears to work and silently yields garbage.
#
# **Writes are generic; reads are not.** Everything below the `loose` line is a
# namespace some module *writes*, and one catch-all serves any module that writes
# there. The two entries under `options` are different: they are values a module
# *reads*, and a catch-all cannot supply those — a read needs a real value, and
# choosing one is a semantic decision.
#
# Which is the interesting part. The reads a wrapped module makes are exactly its
# undeclared dependencies — the things that, in a floe, would be `inputs` or a
# signature. Running this discovery loop against a nixpkgs module is a way to
# *extract its implicit interface*. That is a better migration story than
# wrapping, and it is the one worth building on.
{
  lib,
  pkgs,
  np,
}:

let
  # `loose "systemd.services"` declares that path as a schema-free catch-all.
  loose =
    dotted:
    lib.setAttrByPath ([ "options" ] ++ lib.splitString "." dotted) (
      lib.mkOption {
        type = lib.types.anything;
        default = { };
      }
    );
in
{
  imports = [
    # Real nixpkgs modules, because these are read as well as written and a
    # stub would lie about them.
    "${np}/nixos/modules/misc/assertions.nix"
    "${np}/nixos/modules/misc/ids.nix"
  ]
  # Namespaces the modules write. One catch-all each, shape unknown and
  # unneeded: the floe is a capture harness, not a reimplementation.
  ++ map loose [
    "systemd.services"
    "systemd.tmpfiles"
    "systemd.slices"
    "systemd.targets"
    "systemd.sockets"
    "users.users"
    "users.groups"
    "environment.etc"
    "environment.pathsToLink"
    "environment.systemPackages"
    "services.logrotate"
    "services.dbus"
    "security.acme"
    "security.pam"
    "boot.kernel"
    "boot.kernelModules"
    "networking.firewall"
    "networking.nameservers"
    "networking.resolvconf"
    "programs"
    "meta"
    "system"
  ];

  options = {
    # Values the modules *read*. Each one is a dependency nixpkgs never declared,
    # and each stub here is a decision someone has to make deliberately.
    #
    # nginx reads the running kernel's version to choose sysctl defaults. There
    # is no honest stub for that: it is the real package set.
    boot.kernelPackages = lib.mkOption {
      type = lib.types.raw;
      default = pkgs.linuxPackages;
    };
    networking.enableIPv6 = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };
}

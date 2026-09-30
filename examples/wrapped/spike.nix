# Reproduces the wrapping spike: real, unmodified nixpkgs service modules hosted
# inside isolated `evalModules` calls behind one shared shim.
#
#   nix eval --impure --json --expr \
#     'import ./examples/wrapped/spike.nix { }'
#
#   nix eval --impure --expr \
#     'builtins.deepSeq (import ./examples/wrapped/spike.nix { k = 3; }) 1'
#
# Deliberately not a flake check and deliberately not optimised. It exists so the
# numbers in `README.md` can be re-derived rather than believed, and so the next
# person who wonders "could floes just wrap nixpkgs?" gets an answer in one
# command. `k` takes the first k cases; the first three survive deep forcing and
# the last two do not.
{
  k ? 5,
  np ? builtins.toString <nixpkgs>,
  system ? "x86_64-linux",
}:

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { inherit system; };

  cases = [
    {
      m = "services/web-servers/nginx/default.nix";
      cfg.services.nginx.enable = true;
    }
    {
      m = "services/networking/dnsmasq.nix";
      cfg.services.dnsmasq.enable = true;
    }
    {
      m = "services/monitoring/prometheus/default.nix";
      cfg.services.prometheus.enable = true;
    }
    # Both of these load, and both fail once their output is actually forced —
    # on a *read*, not a write. postgresql wants `config.system.stateVersion`;
    # sshd wants `config.programs.ssh.*`. See `shim.nix` on why that distinction
    # is the whole finding.
    {
      m = "services/databases/postgresql.nix";
      cfg.services.postgresql.enable = true;
    }
    {
      m = "services/networking/ssh/sshd.nix";
      cfg.services.openssh.enable = true;
    }
  ];

  one =
    c:
    let
      ev = lib.evalModules {
        specialArgs = {
          inherit pkgs;
          utils = import "${np}/nixos/lib/utils.nix" {
            inherit lib pkgs;
            config = ev.config;
          };
        };
        modules = [
          "${np}/nixos/modules/${c.m}"
          (import ./shim.nix { inherit lib pkgs np; })
          { config = c.cfg; }
        ];
      };
      cf = ev.config;
    in
    {
      module = c.m;

      # Forced the way a floe's `out` would be: the unit's data, not just its
      # name. `attrNames` alone merges one option and measures nothing.
      units = lib.mapAttrs (_: u: {
        description = u.description or "";
        wantedBy = u.wantedBy or [ ];
        serviceConfigKeys = lib.attrNames (u.serviceConfig or { });
      }) (cf.systemd.services or { });

      users = lib.attrNames (cf.users.users or { });
      groups = lib.attrNames (cf.users.groups or { });

      # The audit, in miniature: namespaces this module wrote that it has no
      # business owning. nginx writes `boot.kernelModules = [ "tls" ]`.
      kernelModules = cf.boot.kernelModules or [ ];
    };
in
map one (lib.take k cases)

# A second REVERSE_PROXY provider, and nothing else.
#
# It exists so the example can show what happens when two floes answer one
# signature: `requires` is exactly-one, so webapp's hole becomes ambiguous and
# the link fails naming both. The deployer resolves it, because a floe author
# cannot — nginx has never heard of caddy.
#
# It claims no ports on purpose. A real caddy would claim 80 and 443 and
# collide with nginx in `networking`, and then the link would have two
# independent errors in it; this file is about one of them.
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
  name = "caddy";
  summary = "Fixture: a second reverse proxy, to make a hole ambiguous.";

  # Writes fixed paths, so two of it would silently merge into one.
  singleton = true;

  requires.network = sigs.NETWORK;
  provides.proxy = sigs.REVERSE_PROXY;

  out.nixosConfig = kinds.nixosConfig (
    T.record {
      services = T.record { caddy = T.record { enable = T.bool; }; };
    }
  );

  body =
    {
      inputs,
      requires,
      collects,
      floe,
    }:
    {
      provides.proxy = {
        baseDomain = requires.network.domain;
        scheme = "https";
      };
      out.nixosConfig.services.caddy.enable = true;
    };
}

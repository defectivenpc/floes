# The fleet link: thirty instances of seven kinds.
#
# This is the realism probe. The small link looks fine at five units; this is
# where ceremony, collection size and evaluation cost become visible.
#
# Scaled by *instantiation* rather than by writing thirty distinct kinds, which
# is both cheaper to write and closer to how a real machine looks: several of a
# few things, not one of many.
#
# What it stresses:
#   - `metrics` collects twenty SCRAPE_TARGETs; `nginx` collects twenty
#     ROUTE_CLAIMs; `networking` collects six PORT_CLAIMs.
#   - Three postgres instances answer DATABASE, so every consumer must say which
#     it means. `deployerCost` counts those binds — that is the ceremony number,
#     not an opinion about it.
#   - Twenty workloads and three databases coexist without one colliding option
#     path, because every floe keys its output by the link's name for it.
{ lib, floes }:

let
  workloads = lib.genList (i: "app${toString (i + 1)}") 20;
  databases = [
    "main"
    "analytics"
    "archive"
  ];

  # Spread the workloads across the databases, round robin. A deployer choosing
  # by hand is the realistic case and this stands in for it.
  dbFor = i: lib.elemAt databases (lib.mod i (lib.length databases));
in
{
  networking = floes.networking.instantiate {
    hostName = "fleet";
    domain = "fleet.test";
  };

  nginx = floes.nginx.instantiate { };
  metrics = floes.metrics.instantiate { interval = "15s"; };
}
// lib.listToAttrs (
  lib.imap0 (
    i: name:
    lib.nameValuePair name (
      # Every port distinct: a claim collision is an error, by design.
      (floes.postgres.instantiate { port = 5432 + i; })
    )
  ) databases
)
// lib.listToAttrs (
  lib.imap0 (
    i: name:
    lib.nameValuePair name (
      (floes.webapp.instantiate { port = 8080 + i; }).bind { database = dbFor i; }
    )
  ) workloads
)
// lib.listToAttrs (
  lib.imap0 (
    i: db: lib.nameValuePair "backup-${db}" ((floes.backup.instantiate { }).bind { database = db; })
  ) databases
)

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

  # Spread the workloads across the databases, round robin. Deliberately
  # adversarial for the `defaults` measurement: a real fleet usually has one
  # dominant database and would see nearly every bind disappear, whereas this
  # spread keeps two thirds of them. The number in `deployerCost` is the
  # pessimistic one on purpose.
  dbFor = i: lib.elemAt databases (lib.mod i (lib.length databases));

  # `main` is the default, so only the workloads that want something else say so.
  bindDb = i: inst: if dbFor i == "main" then inst else inst.bind { database = dbFor i; };
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
    i: name: lib.nameValuePair name (bindDb i (floes.webapp.instantiate { port = 8080 + i; }))
  ) workloads
)
// lib.listToAttrs (
  lib.imap0 (
    i: db: lib.nameValuePair "backup-${db}" (bindDb i (floes.backup.instantiate { }))
  ) databases
)

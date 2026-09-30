# The small link: what a deployer writes, and what the README shows.
#
# Measured — `deployerCost` in `default.nix` counts the meaningful lines here and
# a test fails if it grows. Ergonomics is the question a mechanism demo never
# asks itself, so this file asks it.
#
# Nothing below names a port, a virtual host, an ordering, or a scrape target.
# The ports come from what each service claims, the vhosts from what the
# workloads claim, the ordering from the signatures.
#
# Two Postgres instances, which stock NixOS cannot express with its own module
# at all. `webapp` has to say which one it means, because `requires` is
# exactly-one and there are now two answers — that is the one line multi-instance
# costs the deployer.
{ floes }:

{
  networking = floes.networking.instantiate {
    hostName = "example";
    domain = "example.test";
  };
  nginx = floes.nginx.instantiate { };
  main = floes.postgres.instantiate { port = 5432; };
  analytics = floes.postgres.instantiate { port = 5433; };
  webapp = (floes.webapp.instantiate { }).bind { database = "main"; };
}

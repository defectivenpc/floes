# The whole of what a deployer writes.
#
# Kept in its own file because it is measured: `deployerLines` counts the
# meaningful lines here, and a check fails if it grows. Ergonomics is the
# question a mechanism demo never asks itself, so this file asks it.
#
# Nothing below names a port, a virtual host, a firewall rule or an ordering.
# The ports come from what each service claims, the vhost from what webapp
# claims, and the ordering from the signatures.
{ floes }:

{
  networking = floes.networking.instantiate {
    hostName = "example";
    domain = "example.test";
  };
  nginx = floes.nginx.instantiate { };
  postgres = floes.postgres.instantiate { };
  webapp = floes.webapp.instantiate { };
}

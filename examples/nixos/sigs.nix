# Signatures for the NixOS example.
#
# Five, and the split between them is the whole architecture:
#
#   collected  PORT_CLAIM, ROUTE_CLAIM
#              many contributors, one owner that merges them
#   singular   NETWORK, DATABASE, REVERSE_PROXY
#              exactly one answer in the link
#
# Additive concerns are collected; concerns with one answer are plain holes.
# Neither is a new mechanism a collected signature is just a signature some
# floe names in `collects` rather than in `requires`.
{ floe }:

let
  T = floe.T;
in
{
  PORT_CLAIM = floe.mkSig {
    name = "PORT_CLAIM";
    as = "ports";
    description = "Ports a service needs reachable from outside the machine.";
    fields = {
      tcp = T.listOf T.port;
    };
    # No `service` field: a collection is keyed by the unit that provided it,
    # so the owner already knows who claimed what and its errors can say so.
  };

  SCRAPE_TARGET = floe.mkSig {
    name = "SCRAPE_TARGET";
    as = "scrape";
    description = "A metrics endpoint a workload wants collected.";
    fields = {
      port = T.port;
      path = T.str;
    };
  };

  ROUTE_CLAIM = floe.mkSig {
    name = "ROUTE_CLAIM";
    as = "route";
    description = "A hostname a workload wants routed to one of its local ports.";
    fields = {
      subdomain = T.str;
      port = T.port;
    };
  };

  NETWORK = floe.mkSig {
    name = "NETWORK";
    as = "network";
    description = "The machine's network identity, and what the firewall ended up opening.";
    fields = {
      hostName = T.str;
      domain = T.dnsName;

      # Safe to read from a floe that also claims a port: these come from the
      # networking floe's own inputs, not from the collection.
      externalInterface = T.str;

      # NOT safe to read from such a floe. This is the merge of every
      # PORT_CLAIM, so a contributor that reads it closes the loop. Same hole,
      # same consumer — the field decides whether it recurses, which is why a
      # future safety annotation would have to be per field and not per hole.
      # `broken.nix` has the case and `../refuse.sh` pins what Nix says today.
      openPorts = T.listOf T.port;
    };
  };

  DATABASE = floe.mkSig {
    name = "DATABASE";
    as = "database";
    description = "A Postgres a workload on this machine can reach.";
    fields = {
      host = T.str;
      port = T.port;

      # Concrete: the *path* is decided at eval even though the secret is not.
      passwordFile = T.str;

      # The secret itself, which does not exist until the service has started
      # and generated it. A consumer that interpolates this into NixOS config
      # gets a type error from the linker naming postgres as the source, rather
      # than an attrset where NixOS wanted a string.
      password = T.deferred T.str;
    };

    # Deliberately absent: `dataDir`. Postgres knows it, and in stock NixOS
    # anything that wants it reads `config.services.postgresql.dataDir`.
    # Sealing makes that impossible, so wanting it becomes a request to widen
    # the signature a conversation, instead of a coupling nobody declared.
    # In this way we can guard and direct API design of floes so external parties
    # can depend on it, or participate in designing it through a conversation.
  };

  REVERSE_PROXY = floe.mkSig {
    name = "REVERSE_PROXY";
    as = "proxy";
    description = "Something that routes public hostnames to local ports.";
    fields = {
      baseDomain = T.dnsName;
      scheme = T.enum [
        "http"
        "https"
      ];
    };
  };
}

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
rec {
  PORT_CLAIM = floe.mkSig {
    name = "PORT_CLAIM";
    canonicalName = "ports";
    description = "Ports a service needs reachable from outside the machine.";
    shape = T.record {
      tcp = T.listOf T.port;
    };
    # No `service` field: a collection is keyed by the unit that provided it,
    # so the owner already knows who claimed what and its errors can say so.
  };

  SCRAPE_TARGET = floe.mkSig {
    name = "SCRAPE_TARGET";
    canonicalName = "scrape";
    description = "A metrics endpoint a workload wants collected.";
    shape = T.record {
      port = T.port;
      path = T.str;
    };
  };

  ROUTE_CLAIM = floe.mkSig {
    name = "ROUTE_CLAIM";
    canonicalName = "route";
    description = "A hostname a workload wants routed to one of its local ports.";
    shape = T.record {
      subdomain = T.str;
      port = T.port;
    };
  };

  NETWORK = floe.mkSig {
    name = "NETWORK";
    canonicalName = "network";
    description = "The machine's network identity, and what the firewall ended up opening.";
    shape = T.record {
      hostName = T.str;
      domain = T.dnsName;

      # Safe to read from a floe that also claims a port: these come from the
      # networking floe's own inputs, not from the collection.
      externalInterface = T.str;

      # Derived from the PORT_CLAIM collection this floe folds. A peer that
      # contributes a claim *and* reads this would close the loop — computing its
      # claim needs the fold, and the fold needs its claim. `link` refuses the
      # field to exactly those peers, before anything evaluates, so what used to
      # be `infinite recursion encountered` is now an error naming both floes and
      # the collection.
      #
      # Note it is the field and not the hole: `nginx` requires this same hole
      # from this same floe in this same cycle and is completely fine, because it
      # reads `domain`.
      openPorts = T.derivedFrom PORT_CLAIM (T.listOf T.port);
    };
  };

  # A retrieval signature for this domain, and the whole point of the two
  # examples having one each: `DATABASE.password` is `T.runtime T.str` in both,
  # and the mechanism is entirely different. A Kubernetes provider answers it
  # with `k8s.secretRef`; here it is a file on the host. One signature, two
  # mechanisms — which is only possible because the *provider* declares the
  # retrieval rather than the signature's field doing it.
  FILE_REF = floe.mkSig {
    name = "nixos.fileRef";
    canonicalName = "fileRef";
    description = "Readable from a file on the host, once the unit that writes it has run.";
    shape = floe.T.record {
      path = floe.T.str;
      mode = floe.T.enum [
        "text"
        "firstLine"
      ];
    };
  };

  DATABASE = floe.mkSig {
    name = "DATABASE";
    canonicalName = "database";
    description = "A Postgres a workload on this machine can reach.";
    shape = T.record {
      host = T.str;
      port = T.port;

      # Concrete: the *path* is decided at eval even though the secret is not.
      passwordFile = T.str;

      # The secret itself, which does not exist until the service has started
      # and generated it. A consumer that interpolates this into NixOS config
      # gets a type error from the linker naming postgres as the source, rather
      # than an attrset where NixOS wanted a string.
      password = T.runtime T.str;
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
    canonicalName = "proxy";
    description = "Something that routes public hostnames to local ports.";
    shape = T.record {
      baseDomain = T.dnsName;
      scheme = T.enum [
        "http"
        "https"
      ];
    };
  };
}

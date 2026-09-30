# Pins the two worked examples in `../examples`.
#
# The NixOS half is a probe, not a fixture. It asserts that a service can
# contribute to a namespace it does not own, that two instances of one service
# coexist, that the mutual cycles this creates resolve, and what the deployer
# pays for all of it. It also pins the three ways the example is deliberately
# broken, including the one where floe has nothing useful to say.
{ lib, floe }:

let
  examples = import ../examples { inherit lib floe; };
  inherit (examples) nixos k8s;

  fails = expr: !(builtins.tryEval (builtins.deepSeq expr "evaluated")).success;

  frags = nixos.link.out."nixos.config";
  fleetFrags = nixos.fleet.out."nixos.config";

  # Which units emit a given top-level NixOS namespace.
  emittersOf = f: key: lib.attrNames (lib.filterAttrs (_: frag: frag ? ${key}) f);

  # Every systemd unit any floe in a link emits, and who emitted it.
  unitsOf = f: lib.concatMap (u: lib.attrNames (f.${u}.systemd.services or { })) (lib.attrNames f);

  edge = e: "${e.kind}:${e.from}->${e.to} via ${e.via}";
  edges = lib.sort (a: b: a < b) (map edge nixos.link.graph.edges);
  hasEdge = e: lib.elem e edges;

  # Budgets. Raising one is allowed; doing it without noticing is what the
  # numbers prevent.
  smallLineBudget = 14;
  fleetLineBudget = 45;
in
lib.runTests {

  # ---- The probe -------------------------------------------------------

  # nginx claims 80 and 443, the two postgres instances claim 5432 and 5433, and
  # nothing in the link wrote a firewall rule. In stock NixOS this list is
  # written by hand, or by each module appending to a shared option.
  testCollectedPortsAreMergedByTheOwner = {
    expr = frags.networking.networking.firewall.interfaces.eth0.allowedTCPPorts;
    expected = [
      80
      443
      5432
      5433
    ];
  };

  # The claim that matters, and note which namespaces do *not* need an owner.
  # `networking` is the only emitter of `networking` because a port list merges
  # by policy. `systemd` and `users` have several emitters and that is fine —
  # an attrset keyed by a unique name is disjoint by construction.
  testPolicyMergedNamespacesHaveExactlyOneEmitter = {
    expr = {
      networking = emittersOf frags "networking";
      services = emittersOf frags "services";
      systemd = emittersOf frags "systemd";
      users = emittersOf frags "users";
    };
    expected = {
      networking = [ "networking" ];
      services = [ "nginx" ];
      systemd = [
        "analytics"
        "main"
        "webapp"
      ];
      users = [
        "analytics"
        "main"
      ];
    };
  };

  # The thing stock NixOS cannot do with its own module: two of one service.
  # Distinct units, distinct users, distinct data directories, no collision.
  testTwoDatabaseInstancesCoexist = {
    expr = {
      units = lib.sort (a: b: a < b) (unitsOf frags);
      users = lib.sort (a: b: a < b) (
        lib.concatMap (u: lib.attrNames (frags.${u}.users.users or { })) (lib.attrNames frags)
      );
      dataDirs = lib.sort (a: b: a < b) (
        lib.concatMap (u: frags.${u}.systemd.tmpfiles.rules or [ ]) (lib.attrNames frags)
      );
    };
    expected = {
      units = [
        "postgres-analytics"
        "postgres-main"
        "webapp"
      ];
      users = [
        "postgres-analytics"
        "postgres-main"
      ];
      dataDirs = [
        "d /var/lib/postgres-analytics 0700 postgres-analytics postgres-analytics - -"
        "d /var/lib/postgres-main 0700 postgres-main postgres-main - -"
      ];
    };
  };

  # webapp claimed a subdomain and a port; nginx and networking between them
  # turned that into a virtual host. The deployer named neither.
  testTheVirtualHostIsDerivedFromAClaim = {
    expr = lib.attrNames frags.nginx.services.nginx.virtualHosts;
    expected = [ "webapp.example.test" ];
  };

  # Both directions, twice over: nginx needs the domain while networking needs
  # nginx's ports, and nginx needs webapp's route while webapp needs nginx's base
  # domain. Laziness resolves both. This is the half of the recursion problem
  # floe does solve.
  testMutualCyclesResolve = {
    expr = {
      networkingNeedsNginx = hasEdge "eval:networking->nginx via claims";
      nginxNeedsNetworking = hasEdge "eval:nginx->networking via network";
      nginxNeedsWebapp = hasEdge "eval:nginx->webapp via routes";
      webappNeedsNginx = hasEdge "eval:webapp->nginx via proxy";
    };
    expected = {
      networkingNeedsNginx = true;
      nginxNeedsNetworking = true;
      nginxNeedsWebapp = true;
      webappNeedsNginx = true;
    };
  };

  # postgres knows its `dataDir` and does not promise it, so a consumer cannot
  # reach it. In stock NixOS the equivalent read is one attribute away.
  testSealingOmitsWhatTheSignatureDoesNotPromise = {
    expr = lib.attrNames nixos.link.provides.main.database;
    expected = [
      "host"
      "password"
      "passwordFile"
      "port"
    ];
  };

  # ---- What the deployer pays ------------------------------------------

  # The ceremony number, not an opinion about it.
  #
  # A second provider of a signature used to break every existing consumer of it.
  # `link { defaults.DATABASE = "main"; }` is one line that keeps the consumers
  # with no opinion working, and it took the fleet from twenty-three binds to
  # fifteen — against a deliberately adversarial round-robin spread across three
  # databases. A fleet with one dominant database would keep almost none.
  testDeployerCost = {
    expr = nixos.deployerCost;
    expected = {
      small = {
        lines = 11;
        unitCount = 5;
        binds = 1;
      };
      fleet = {
        lines = 37;
        unitCount = 29;
        binds = 15;
      };
    };
  };

  # And the default did not silently collapse them: each backup still dumps a
  # different database. A default that quietly merged consumers would be worse
  # than the breakage it replaced.
  testTheDefaultDoesNotCollapseConsumers = {
    expr =
      let
        f = nixos.fleet.out."nixos.config";
      in
      lib.sort (a: b: a < b) (
        lib.concatMap (
          u: lib.mapAttrsToList (_: v: v.serviceConfig.ExecStart) (f.${u}.systemd.services or { })
        ) (lib.filter (lib.hasPrefix "backup-") (lib.attrNames f))
      );
    expected = [
      "/run/current-system/sw/bin/pg_dump -h 127.0.0.1 -p 5432"
      "/run/current-system/sw/bin/pg_dump -h 127.0.0.1 -p 5433"
      "/run/current-system/sw/bin/pg_dump -h 127.0.0.1 -p 5434"
    ];
  };

  testTheDeployerBlocksStayWithinBudget = {
    expr =
      let
        c = nixos.deployerCost;
      in
      lib.filter (x: x != null) [
        (if c.small.lines <= smallLineBudget then null else "small grew to ${toString c.small.lines}")
        (if c.fleet.lines <= fleetLineBudget then null else "fleet grew to ${toString c.fleet.lines}")
      ];
    expected = [ ];
  };

  # One edit propagates. Moving webapp to another port changes one number in one
  # place and the proxy target follows; in stock NixOS the same edit touches
  # three places and nothing notices if you forget one.
  testOneEditPropagates = {
    expr =
      let
        moved = floe.link {
          units = nixos.units // {
            webapp = (nixos.floes.webapp.instantiate { port = 9090; }).bind { database = "main"; };
          };
        };
        out = moved.out."nixos.config";
      in
      {
        proxyTarget = out.nginx.services.nginx.virtualHosts."webapp.example.test".locations."/".proxyPass;
        # Unchanged, and worth pinning: webapp is behind the proxy, so moving it
        # must *not* open a port.
        openPorts = out.networking.networking.firewall.interfaces.eth0.allowedTCPPorts;
      };
    expected = {
      proxyTarget = "http://127.0.0.1:9090";
      openPorts = [
        80
        443
        5432
        5433
      ];
    };
  };

  # ---- The fleet -------------------------------------------------------

  # Twenty workloads, three databases, two twenty-member collections, and not one
  # colliding option path — because every floe keys its output by the link's name
  # for it.
  testTheFleetFansInWithoutColliding = {
    expr = {
      unitCount = lib.length (lib.attrNames nixos.fleetUnits);
      systemdUnits = lib.length (unitsOf fleetFrags);
      vhosts = lib.length (lib.attrNames fleetFrags.nginx.services.nginx.virtualHosts);
      scrapeStanzas = lib.count (l: lib.hasPrefix "- job_name" l) (
        lib.splitString "\n" fleetFrags.metrics.environment.etc."prometheus.yml".text
      );
      openPorts = fleetFrags.networking.networking.firewall.interfaces.eth0.allowedTCPPorts;
      edges = lib.length nixos.fleet.graph.edges;
    };
    expected = {
      unitCount = 29;
      # 20 workloads + 3 postgres + 3 backups + prometheus = 27.
      systemdUnits = 27;
      vhosts = 20;
      scrapeStanzas = 20;
      openPorts = [
        80
        443
        5432
        5433
        5434
        9090
      ];
      edges = 90;
    };
  };

  # Every workload's subdomain defaults to the link's name for it, so twenty
  # distinct hostnames cost the deployer nothing.
  testWorkloadHostnamesAreUniqueWithoutBeingNamed = {
    expr =
      let
        hosts = lib.attrNames fleetFrags.nginx.services.nginx.virtualHosts;
      in
      {
        count = lib.length hosts;
        first = lib.head (lib.sort (a: b: a < b) hosts);
      };
    expected = {
      count = 20;
      first = "app1.fleet.test";
    };
  };

  # ---- The five refusals -----------------------------------------------

  testTwoProxiesLeaveTheHoleAmbiguous = {
    expr = fails nixos.ambiguousProxy.out;
    expected = true;
  };

  testABindingResolvesTheAmbiguity = {
    expr = nixos.boundProxy.out."nixos.config".webapp.systemd.services.webapp.environment.PUBLIC_URL;
    expected = "http://webapp.example.test";
  };

  # The owner's own merge policy, not the module system's. A stock NixOS firewall
  # list would have concatenated and the clash would have waited for the second
  # unit to fail to start.
  testTwoInstancesClaimingOnePortIsRefused = {
    expr = fails nixos.portCollision.out;
    expected = true;
  };

  # The same shape, a different owner: `mapAttrs'` would have silently kept one
  # virtual host and left the other workload unreachable.
  testTwoWorkloadsClaimingOneHostnameIsRefused = {
    expr = fails nixos.hostnameCollision.out;
    expected = true;
  };

  # A value that does not exist until after apply, put where NixOS config wants a
  # string. The linker names the floe it came from and the phase.
  testADeferredValueInConfigIsRefused = {
    expr = fails nixos.broken.leaky.out;
    expected = true;
  };

  # Two instances of a floe that writes fixed paths. The one failure here that
  # nothing downstream could catch: both fragments are *identical*, so every
  # merge accepts them and the deployer silently gets one of the thing.
  testTwoInstancesOfASingletonFloeIsRefused = {
    expr = fails nixos.twoSingletons.out;
    expected = true;
  };

  # ---- The escape hatch ------------------------------------------------

  # The honest answer to "I need a flag the floe doesn't expose": patch the
  # fragment on the way out. It works today with no library support, because the
  # adapter is the deployer's own function — and it costs what a post-renderer
  # costs, which `default.nix` spells out.
  testTheOutputCanBePatchedByTheDeployer = {
    expr =
      let
        nginxModule = lib.head (lib.filter (m: m._file == "floe:nginx") nixos.patchedNginx);
      in
      {
        patched = nginxModule.config.services.nginx.clientMaxBodySize;
        # The patch is additive: what the floe computed is still there.
        vhostsSurvive = lib.attrNames nginxModule.config.services.nginx.virtualHosts;
      };
    expected = {
      patched = "64m";
      vhostsSurvive = [ "webapp.example.test" ];
    };
  };

  # The error that used to be the worst in the system, now the best.
  #
  # `NETWORK.openPorts` is `T.derivedFrom PORT_CLAIM`, and `offender` contributes
  # a PORT_CLAIM, so `link` refuses it that one field before anything evaluates.
  # Before the marking existed this was `infinite recursion encountered` with no
  # floe, hole or field named — and it was not even catchable by `tryEval`, so no
  # test could hold it and nothing could wrap it in a better message.
  #
  # Note what still works: `nginx` requires the same hole from the same floe in
  # the same cycle and reads `domain`, which is fine. The field decides it.
  testAReadOfTheCollectionAContributorFeedsIsRefused = {
    expr = fails nixos.broken.greedy.out;
    expected = true;
  };

  # One deliberate mistake still has no test, and still cannot have one.
  # `builtins.tryEval` catches `throw` and `assert`, and nothing else, so
  # testability tracks *who reported the failure*:
  #
  #   broken.leaky          floe's own `throw`      catchable, tested above
  #   broken.greedy         floe's own `throw`      catchable, tested above
  #   broken.interpolating  Nix: cannot coerce      escapes tryEval
  #
  # The middle row used to be in the third group. `T.derivedFrom` moved it, which
  # is the whole argument for rejecting a bad read before evaluating rather than
  # trying to explain it afterwards. The one that remains is RFC 0001's open
  # question 1 — deferred transparency in interpolation — and it is pinned in
  # `examples/refuse.sh`, where a non-zero exit is the assertion.

  # ---- The contrast ----------------------------------------------------

  # No collections, no mutual edges: resolution is a chain, and the only ordering
  # is the one the deferred CA fingerprint forces.
  testTheKubernetesExampleResolvesAsAChain = {
    expr = k8s.link.phases;
    expected = {
      cluster = 0;
      cert-manager = 0;
      podinfo = 1;
    };
  };

  testTheKubernetesExampleCollectsNothing = {
    expr = lib.all (f: f.collects == { }) (lib.attrValues k8s.floes);
    expected = true;
  };
}

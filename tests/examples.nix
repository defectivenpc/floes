# Pins the two worked examples in `../examples`.
#
# The NixOS half is a probe, not a fixture: it asserts that a service can
# contribute to a namespace it does not own, that only the owner emits that
# namespace, and that the mutual cycle this creates resolves. It also pins the
# three ways the example is deliberately broken, including the one where floe
# has nothing useful to say.
{ lib, floe }:

let
  examples = import ../examples { inherit lib floe; };
  inherit (examples) nixos k8s;

  fails = expr: !(builtins.tryEval (builtins.deepSeq expr "evaluated")).success;

  fragments = nixos.link.out."nixos.config";

  # Which units emit a given top-level NixOS namespace.
  emittersOf = key: lib.attrNames (lib.filterAttrs (_: f: f ? ${key}) fragments);

  edge = e: "${e.kind}:${e.from}->${e.to} via ${e.via}";
  nixosEdges = lib.sort (a: b: a < b) (map edge nixos.link.graph.edges);

  # What a deployer may write before someone has to justify it. Raising this
  # is allowed; doing it without noticing is what the number prevents.
  deployerBudget = 12;
in
lib.runTests {

  # ---- The probe -------------------------------------------------------

  # nginx claims 80 and 443, postgres claims 5432, and nothing in the link
  # wrote a firewall rule. In stock NixOS this list is written by hand, or by
  # each module appending to a shared option.
  testCollectedPortsAreMergedByTheOwner = {
    expr = fragments.networking.networking.firewall.interfaces.eth0.allowedTCPPorts;
    expected = [
      80
      443
      5432
    ];
  };

  # The claim that matters: one namespace, one emitter. Two services
  # contributed to `networking` and neither of them wrote it.
  testOnlyTheOwnerEmitsItsNamespace = {
    expr = {
      networking = emittersOf "networking";
      services = emittersOf "services";
      systemd = emittersOf "systemd";
    };
    expected = {
      networking = [ "networking" ];
      services = [
        "nginx"
        "postgres"
      ];
      systemd = [ "webapp" ];
    };
  };

  # webapp claimed a subdomain and a port; nginx and networking between them
  # turned that into a virtual host. The deployer named neither.
  testTheVirtualHostIsDerivedFromAClaim = {
    expr = lib.attrNames fragments.nginx.services.nginx.virtualHosts;
    expected = [ "app.example.test" ];
  };

  # Both directions, in a four-floe link, twice over: nginx needs the domain
  # while networking needs nginx's ports, and nginx needs webapp's route while
  # webapp needs nginx's base domain. Laziness resolves both, which is the
  # half of the recursion problem floe does solve.
  testMutualCyclesResolve = {
    expr = nixosEdges;
    expected = [
      "eval:networking->nginx via claims"
      "eval:networking->postgres via claims"
      "eval:nginx->networking via network"
      "eval:nginx->webapp via routes"
      "eval:webapp->nginx via proxy"
      "eval:webapp->postgres via database"
    ];
  };

  # postgres knows its `dataDir` and does not promise it, so a consumer cannot
  # reach it. In stock NixOS the equivalent read is one attribute away.
  testSealingOmitsWhatTheSignatureDoesNotPromise = {
    expr = lib.attrNames nixos.link.provides.postgres.database;
    expected = [
      "host"
      "password"
      "passwordFile"
      "port"
    ];
  };

  # ---- What the deployer writes ----------------------------------------

  testTheDeployerBlockStaysSmall = {
    expr =
      if nixos.deployerLines <= deployerBudget then
        "ok"
      else
        "system.nix grew to ${toString nixos.deployerLines} meaningful lines";
    expected = "ok";
  };

  # The ergonomic claim, as an assertion rather than a boast. Moving webapp to
  # another port changes one number in one place, and the firewall rule and the
  # proxy target both follow. In stock NixOS the same edit touches three places
  # and nothing notices if you forget one.
  testOneEditPropagates = {
    expr =
      let
        moved = floe.link {
          units = nixos.units // {
            webapp = nixos.floes.webapp.instantiate { port = 9090; };
          };
        };
        out = moved.out."nixos.config";
      in
      {
        proxyTarget = out.nginx.services.nginx.virtualHosts."app.example.test".locations."/".proxyPass;
        listenPort = out.webapp.systemd.services.webapp.environment.LISTEN_PORT;
        # Unchanged, and worth pinning: webapp is behind the proxy, so moving
        # it must *not* open a port.
        openPorts = out.networking.networking.firewall.interfaces.eth0.allowedTCPPorts;
      };
    expected = {
      proxyTarget = "http://127.0.0.1:9090";
      listenPort = "9090";
      openPorts = [
        80
        443
        5432
      ];
    };
  };

  # ---- The four refusals -----------------------------------------------

  testTwoProxiesLeaveTheHoleAmbiguous = {
    expr = fails nixos.ambiguousProxy.out;
    expected = true;
  };

  testABindingResolvesTheAmbiguity = {
    expr = nixos.boundProxy.out."nixos.config".webapp.systemd.services.webapp.environment.PUBLIC_URL;
    expected = "http://app.example.test";
  };

  # The owner's own merge policy, not the module system's. A stock NixOS
  # firewall list would have concatenated and the clash would have waited for
  # the second unit to fail to start.
  testTwoServicesClaimingOnePortIsRefused = {
    expr = fails nixos.portCollision.out;
    expected = true;
  };

  # A value that does not exist until after apply, put where NixOS config
  # wants a string. The linker names the floe it came from and the phase.
  testADeferredValueInConfigIsRefused = {
    expr = fails nixos.broken.leaky.out;
    expected = true;
  };

  # Two of the deliberate mistakes have no test here, and cannot have one.
  #
  # `builtins.tryEval` catches `throw` and `assert`, and nothing else. So
  # whether a failure is testable turns out to track *who reported it*:
  #
  #   broken.leaky          floe's own `throw`     catchable, tested above
  #   broken.interpolating  Nix: cannot coerce     escapes tryEval
  #   broken.greedy         Nix: infinite recursion  escapes tryEval
  #
  # `fails` on either of the last two takes the whole evaluation down with it.
  # That is worth more than two passing tests, because it means the bad message
  # cannot be wrapped in a better one either — nothing gets to run after it. A
  # readable error for a structural read in a cycle has to come from rejecting
  # the cycle *before* any body evaluates, which is what RFC 0001's
  # stratification check would do, and why it is not merely cosmetic.
  #
  # Both are pinned in the `examples-refuse` flake check, where a non-zero exit
  # from `nix eval` is the assertion.

  # ---- The contrast ----------------------------------------------------

  # No collections, no mutual edges: resolution is a chain, and the only
  # ordering is the one the deferred CA fingerprint forces.
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

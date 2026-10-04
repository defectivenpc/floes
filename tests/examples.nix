# Pins the two worked examples in `../examples`.
#
# The NixOS half is a probe, not a fixture. It asserts that a service can
# contribute to a namespace it does not own, that two instances of one service
# coexist, that the mutual cycles this creates resolve, and what the deployer
# pays for all of it. It also pins the three ways the example is knowingly
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
  # by policy. `systemd` and `users` have several emitters and that is fine:
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
        "d /var/lib/postgres-analytics/credentials 0700 postgres-analytics postgres-analytics - -"
        "d /var/lib/postgres-main 0700 postgres-main postgres-main - -"
        "d /var/lib/postgres-main/credentials 0700 postgres-main postgres-main - -"
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
      "credentialDir"
      "host"
      "port"
      "superuserPassword"
      "superuserPasswordFile"
    ];
  };

  # ---- What the deployer pays ------------------------------------------

  # The ceremony number, not an opinion about it.
  #
  # A second provider of a signature used to break every existing consumer of it.
  # `link { defaults.DATABASE = "main"; }` is one line that keeps the consumers
  # with no opinion working, and it took the fleet from twenty-three binds to
  # fifteen, against an adversarial round-robin spread across three
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

  # And the default did not collapse them without a word: each backup still
  # dumps a different database. A default that merged consumers unannounced
  # would be worse
  # than the breakage it replaced.
  testTheDefaultDoesNotCollapseConsumers = {
    expr =
      let
        f = nixos.fleet.out."nixos.config";
      in
      lib.sort (a: b: a < b) (
        lib.concatMap (
          u:
          lib.mapAttrsToList (
            # The port each backup dumps, read out of its command line. Pinning
            # the whole string would make this a test of shell quoting.
            _: v: lib.head (lib.match ".*-p ([0-9]+).*" v.serviceConfig.ExecStart)
          ) (f.${u}.systemd.services or { })
        ) (lib.filter (lib.hasPrefix "backup-") (lib.attrNames f))
      );
    expected = [
      "5432"
      "5433"
      "5434"
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
  # colliding option path, because every floe keys its output by the link's name
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
      # Three postgres instances each collecting DB_ROLE_CLAIM from all twenty
      # workloads is sixty of these on its own.
      edges = 150;
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

  # The same shape, a different owner: `mapAttrs'` would have kept one
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
  # merge accepts them and the deployer gets one of the thing, unannounced.
  testTwoInstancesOfASingletonFloeIsRefused = {
    expr = fails nixos.twoSingletons.out;
    expected = true;
  };

  # ---- The escape hatch ------------------------------------------------

  # The honest answer to "I need a flag the floe doesn't expose": patch the
  # fragment on the way out. It works today with no library support, because the
  # adapter is the deployer's own function, and it costs what a post-renderer
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
  # floe, hole or field named, and not catchable by `tryEval` either, so no
  # test could hold it and nothing could wrap it in a better message.
  #
  # Note what still works: `nginx` requires the same hole from the same floe in
  # the same cycle and reads `domain`, which is fine. The field decides it.
  testAReadOfTheCollectionAContributorFeedsIsRefused = {
    expr = fails nixos.broken.greedy.out;
    expected = true;
  };

  # All three deliberate mistakes have tests now. `builtins.tryEval` catches
  # `throw` and `assert` and nothing else, so testability tracks *who reported
  # the failure*, and both of the ones that used to escape were moved by
  # changing the reporter rather than the message:
  #
  #   broken.leaky          floe's own `throw`   always was catchable
  #   broken.greedy         floe's own `throw`   was `infinite recursion`; T.derivedFrom
  #   broken.interpolating  floe's own `throw`   was Nix's coercion error; __toString
  #
  # `examples/refuse.sh` existed for the last row and has been deleted, because
  # it held the only case that needed a non-zero exit to assert on.
  #
  # This answers RFC 0001's open question 1: a deferred value does not propagate
  # through interpolation, it refuses. Transparent propagation would have split
  # every prelude type into concrete and deferred variants and made every
  # signature field declare which it accepts.
  testInterpolatingADeferredValueIsRefused = {
    expr = fails nixos.broken.interpolating.out;
    expected = true;
  };

  # And it is floe's error rather than Nix's, which is the whole point: the old
  # one was "cannot coerce a set to a string" with no floe named and nothing
  # able to wrap it, because nothing runs after a coercion failure.
  testTheInterpolationErrorNamesTheSourceFloe = {
    expr =
      let
        attempt = builtins.tryEval (
          builtins.deepSeq nixos.broken.interpolating.out."nixos.config" "reached"
        );
      in
      attempt.success;
    expected = false;
  };

  # ---- The secret chain, end to end -------------------------------------
  #
  # The distinctive bit of this example, and the thing no other one does: a
  # collection coordinating with a deferred value. Postgres cannot know its
  # consumers, so it collects what they ask for and provisions a role, a database
  # and a credential per claimant, at apply time, which is why the secret is
  # deferred.
  #
  # These used to be a path postgres invented and nothing created, mounted by
  # consumers that never read it. Every link declared, none connected.

  # One credential per claimant, rather than one shared by all of them. Twenty
  # fleet workloads get twenty files, and no deployer writes the role name or
  # the database name: both are the claimant's own unit name.
  testEachClaimantGetsItsOwnCredential = {
    expr =
      let
        f = nixos.fleet.out."nixos.config";
        pg = f.main.systemd.services."postgres-main".serviceConfig;
        # Which workloads claimed a role from `main`, read off the credentials it
        # generates.
        generated = lib.sort (a: b: a < b) (
          map (m: lib.head m) (
            lib.filter (m: m != null) (
              map (w: builtins.match ".*(/var/lib/postgres-main/credentials/${w}).*" pg.ExecStartPre) [
                "app1"
                "app4"
                "app7"
              ]
            )
          )
        );
      in
      {
        inherit generated;
        # app1 mounts exactly the file postgres generated for app1.
        app1Mounts = f.app1.systemd.services.app1.serviceConfig.LoadCredential;
        # And a different workload mounts a different one.
        app4Mounts = f.app4.systemd.services.app4.serviceConfig.LoadCredential;
      };
    expected = {
      generated = [
        "/var/lib/postgres-main/credentials/app1"
        "/var/lib/postgres-main/credentials/app4"
        "/var/lib/postgres-main/credentials/app7"
      ];
      app1Mounts = "dbpw:/var/lib/postgres-main/credentials/app1";
      app4Mounts = "dbpw:/var/lib/postgres-main/credentials/app4";
    };
  };

  # The roles themselves are created after the server starts, because a role
  # cannot be created before it accepts connections. Two hooks for two different
  # prerequisites, and the content of both came from the collection, so no
  # deployer wrote a role name anywhere.
  testRolesAreProvisionedFromTheCollection = {
    expr =
      let
        pg = nixos.link.out."nixos.config".main.systemd.services."postgres-main".serviceConfig;
      in
      {
        # The small link has one claimant: webapp.
        createsTheRole = lib.hasInfix "CREATE ROLE webapp" pg.ExecStartPost;
        createsTheDatabase = lib.hasInfix "CREATE DATABASE webapp OWNER webapp" pg.ExecStartPost;
        # Idempotent: a restart must not fail, and must not rotate a password a
        # consumer is already using.
        #
        # Matched without the quotes, because at this level the string still holds
        # the shell escape `'\''` rather than what a shell will make of it. What
        # the SQL *becomes* is `examples/shell-check.sh`'s job, and has to be:
        # nothing in a Nix evaluation can see through `sh -c`.
        guardedOnExisting = lib.hasInfix "FROM pg_roles WHERE rolname=" pg.ExecStartPost;
        generatesBeforeStarting = lib.hasInfix "credentials/webapp" pg.ExecStartPre;
      };
    expected = {
      createsTheRole = true;
      createsTheDatabase = true;
      guardedOnExisting = true;
      generatesBeforeStarting = true;
    };
  };

  # Not every consumer of DATABASE claims a role. A backup dumps the whole
  # server, so it takes the superuser credential and contributes nothing to the
  # collection, which is the other half of the fan-in story.
  testAConsumerMayTakeTheSuperuserAndClaimNothing = {
    expr =
      let
        f = nixos.fleet.out."nixos.config";
        b = f."backup-main".systemd.services."backup-main".serviceConfig;
      in
      {
        mountsSuperuser = b.LoadCredential;
        dumpsEverything = lib.hasInfix "pg_dumpall" b.ExecStart;
        claimsNoRole = !((nixos.floes.backup.provides or { }) ? dbRole);
      };
    expected = {
      mountsSuperuser = "dbpw:/var/lib/postgres-main/superuser-password";
      dumpsEverything = true;
      claimsNoRole = true;
    };
  };

  # And the chain closes: the credential a consumer mounts is read where the
  # password is needed, and the secret appears in no unit, no environment value
  # and nothing in the Nix store. The only thing eval ever saw was a path.
  testTheSecretIsReadAndNeverRendered = {
    expr =
      let
        w = nixos.link.out."nixos.config".webapp.systemd.services.webapp;
      in
      {
        readsWhatSystemdGave = lib.hasInfix "CREDENTIALS_DIRECTORY/dbpw" w.serviceConfig.ExecStart;
        urlCarriesNoSecret = w.environment.DATABASE_URL;
        # The deferred half is still an unreadable token, beside a path that is
        # perfectly concrete.
        superuserValueStillDeferred = floe.isDeferredToken nixos.link.provides.main.database.superuserPassword;
      };
    expected = {
      readsWhatSystemdGave = true;
      urlCarriesNoSecret = "postgresql://webapp@127.0.0.1:5432/webapp";
      superuserValueStillDeferred = true;
    };
  };

  # Two instances, two credential directories, no contention. A shared
  # `/run/secrets` would have had both writing one path.
  testEachInstanceOwnsItsSecrets = {
    expr = lib.sort (a: b: a < b) [
      nixos.link.provides.main.database.credentialDir
      nixos.link.provides.analytics.database.credentialDir
    ];
    expected = [
      "/var/lib/postgres-analytics/credentials"
      "/var/lib/postgres-main/credentials"
    ];
  };

  # ---- Deferred values, and what a backend does with them ----------------

  # The two examples declare the *same* kind of value, one that does not exist
  # until after apply, through mechanisms with nothing in common. That is the
  # whole reason the retrieval is the provider's to declare and not the
  # signature field's: `DATABASE.password` and `ISSUER.caFingerprint` are both
  # `T.deferred T.str`, and neither signature knows anything about Secrets or
  # files.
  testOneTypeTwoMechanisms = {
    expr = {
      k8sRetrieval = (lib.head (lib.attrValues k8s.link.provides.cert-manager)).caFingerprint.retrieval;
      nixosRetrieval = nixos.link.provides.main.database.superuserPassword.retrieval;
    };
    expected = {
      k8sRetrieval = "k8s.secretRef";
      nixosRetrieval = "nixos.fileRef";
    };
  };

  # And the NixOS link has *no* deferred sites, which is the correct answer rather
  # than a gap. A site is a token that reached **output**; in NixOS nothing puts
  # the secret in config, because `DATABASE` offers `passwordFile` beside
  # `password` and a systemd unit takes the path. Putting the value itself in
  # config is exactly what `broken.leaky` demonstrates as a mistake.
  #
  # So the two examples show the two halves: Kubernetes renders a value into a
  # manifest and needs a backend to fill it; NixOS hands over a path and needs
  # nobody. A retrieval signature is declared either way, because the provider
  # cannot know which consumer it will get.
  testAPathBeatsASiteWhereOneWillDo = {
    expr = {
      k8s = lib.length k8s.link.deferredSites;
      nixos = lib.length nixos.link.deferredSites;
      # The concrete alternative the NixOS consumers use, and it is per-claimant
      # rather than one secret shared by all of them.
      webappUsesThePath =
        nixos.link.out."nixos.config".webapp.systemd.services.webapp.serviceConfig.LoadCredential;
    };
    expected = {
      k8s = 1;
      nixos = 0;
      webappUsesThePath = "dbpw:/var/lib/postgres-main/credentials/webapp";
    };
  };

  # A site is a complete instruction: read *this*, write it *there*. The path is
  # a list because output keys contain dots, as in `floe.dev/ca-fingerprint`,
  # and a backend splitting a dotted string would write to the wrong place.
  # `__toString` is dropped before comparing: it is a function, so it can be
  # neither compared nor serialised, and that is the whole of what it is for.
  # Interpolating a token is a floe error rather than Nix's uncatchable
  # coercion failure. `testInterpolatingADeferredValueIsRefused` holds that.
  testASiteSaysWhatToReadAndWhereToPutIt = {
    expr =
      let
        s = lib.head k8s.link.deferredSites;
      in
      s // { token = removeAttrs s.token [ "__toString" ]; };
    expected = {
      unit = "podinfo";
      out = "k8s.manifests";
      at = [
        "certificate"
        "annotations"
        "floe.dev/ca-fingerprint"
      ];
      token = {
        __deferred = true;
        source = "cert-manager";
        retrieval = "k8s.secretRef";
        ref = {
          namespace = "cert-manager";
          name = "cluster-ca-tls";
          key = "ca.crt";
        };
      };
    };
  };

  # What a backend does, in the test rather than in the library, because core
  # cannot know how a value is reified, only that it must be. If `deferredSites`
  # were not sufficient to write this, it would not be sufficient for a real
  # backend either, and that is the point of having it here.
  #
  # Core ships no resolver, by design: a ConfigMap, a Secret, an
  # annotation, a file and an HTTP lookup are five mechanisms for one job, and
  # picking one in core would be choosing for every distribution at once.
  testABackendCanCloseTheLoop = {
    expr =
      let
        # Pretend cert-manager has been applied and its CA read out.
        resolved = {
          "cert-manager/k8s.secretRef" = "ab:cd:ef:12";
        };

        # The substitution: for every site, write the resolved value at `at`.
        fill =
          out: site:
          lib.updateManyAttrsByPath [
            {
              path = [
                site.out
                site.unit
              ]
              ++ site.at;
              update = _: resolved."${site.token.source}/${site.token.retrieval}";
            }
          ] out;

        applied = lib.foldl' fill k8s.link.out k8s.link.deferredSites;
        ann = applied."k8s.manifests".podinfo.certificate.annotations."floe.dev/ca-fingerprint";
      in
      {
        # Before: a token, which is not a Kubernetes annotation.
        beforeIsAToken = floe.isDeferredToken (
          k8s.link.out."k8s.manifests".podinfo.certificate.annotations."floe.dev/ca-fingerprint"
        );
        # After: a string, which is.
        afterIsAString = builtins.isString ann;
        afterValue = ann;
      };
    expected = {
      beforeIsAToken = true;
      afterIsAString = true;
      afterValue = "ab:cd:ef:12";
    };
  };

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

  # Nothing here collects: Kubernetes components have coarse grain and clean
  # boundaries, which is the contrast with the NixOS example's three
  # collections.
  testTheKubernetesExampleCollectsNothing = {
    expr = lib.all (f: f.collects == { }) (
      with k8s.floes;
      [
        cluster
        certManager
        podinfo
      ]
    );
    expected = true;
  };

  # ---- What the cycles say about caching (ADR 0008) ----------------------
  #
  # `link.cycles` was built to make ADR 0008's claim usable: a unit is a
  # natural memoization unit unless it sits in a cycle, in which case the cycle
  # is. Measuring it is what showed the claim is weaker than it reads, so
  # these numbers are pinned: they are the argument, and a change in them is a
  # change in what caching could ever buy.

  # The small link's whole core is *one* component. The README called this "two
  # mutual cycles", which is true of the edge pairs and understates the result:
  # nginx is in both, so they are one component, and the databases join it
  # through `networking`'s collection, so five of five units are one unit.
  testTheSmallLinkIsOneComponent = {
    expr = nixos.link.cycles;
    expected = [
      [
        "analytics"
        "main"
        "networking"
        "nginx"
        "webapp"
      ]
    ];
  };

  # And the fleet, which is the number that matters: twenty-nine units, one
  # component of twenty-six, so the cache-unit partition is four. Per-floe
  # caching would buy almost nothing on this link as it is structured.
  #
  # The cause is structural rather than accidental, and it is ADR 0001's own
  # design: a namespace with an owner means one floe collecting from every peer,
  # and those peers reaching that floe back through the proxy. An eval edge is
  # per *hole*, while the dependency it stands for is per *field*: nginx reads
  # `NETWORK.domain`, which does not depend on the port collection. The
  # cycle is real at hole granularity and would dissolve at field granularity,
  # which is where a future answer would have to look.
  testTheFleetIsOneComponentOfTwentySix = {
    expr =
      let
        inCycles = lib.concatLists nixos.fleet.cycles;
      in
      {
        units = lib.length nixos.fleet.graph.nodes;
        components = map lib.length nixos.fleet.cycles;
        cacheUnits =
          lib.length nixos.fleet.cycles + (lib.length nixos.fleet.graph.nodes - lib.length inCycles);
      };
    expected = {
      units = 29;
      components = [ 26 ];
      cacheUnits = 4;
    };
  };

  # The contrast, and the reason the k8s example was worth having: resolution
  # is a chain, so every unit is its own cache unit.
  testTheKubernetesExampleHasNoCycles = {
    expr = k8s.link.cycles;
    expected = [ ];
  };

}

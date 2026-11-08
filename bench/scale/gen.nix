# One seeded spec, two programs: a floe distribution and a NixOS-module twin
# with the same topology, computing the same output. `tests/scale.nix` pins
# that the two agree, which is what makes a cost difference between them a
# difference of mechanism rather than of workload.
#
# The shape is nixpkgs' own, measured on the `flake.lock` pin (25.11pre):
#
#   catalogue      1,964 modules                -> `catalogue` service floes
#   inputs/module  median 5, p90 16, max 170    -> `weightOf`
#   input types    8% submodule-typed           -> `typeOf`
#   fan-in         systemd.services 1,322 files -> `domains`, each `p` the
#                  share of the catalogue that writes that namespace
#
# A *service* is a nixpkgs service module: deployer inputs, a provide its
# peers read (`SVC_i`, and `SVCX_i` for half of them), `requires` on peers in
# the layer below and on 1-3 domains, and a claim into each domain it writes.
# A *domain* is an owned namespace, ADR 0001's design: a singleton collecting
# every claim and the only thing emitting it, and providing `ports`, a field
# derived from that fold, to whoever does not contribute to it.
#
# The twin imports every catalogue module behind `mkIf enable`, as
# `module-list.nix` does. The floe side instantiates only the linked ones,
# which is the property under test and so not something to equalise away.
{
  lib,
  floe ? import ../../lib { inherit lib; },
  # Units linked, and modules enabled in the twin: the first `n` of the
  # catalogue, which is closed under `requires` because a peer is always an
  # earlier floe.
  n ? 150,
  catalogue ? 2000,
  seed ? "floe",
  # Longest `requires` chain between services. Layer of floe i is
  # `i mod (depth + 1)`, and a floe requires only from the layer below.
  depth ? 2,
  # How many domains every service contributes to, most-written first; `null`
  # samples nixpkgs' shares instead. `fanOut = 10` puts every unit into every
  # collection, the maximum fan-in a link of `n` can have.
  fanOut ? null,
  # Inclusions wrapped around the whole host link. 1 is flat. Floe-only:
  # NixOS `imports` flatten, so there is nothing on the twin side to nest.
  nest ? 1,
  # Instances of each of the first `n / 10` services. Floe-only: a NixOS
  # module's option paths are fixed, so it cannot be instantiated twice.
  instances ? 1,
  # One injected mistake, or null. See `faults` at the bottom.
  fault ? null,
}:

let
  T = floe.T;
  inherit (lib) types mkOption;

  # ---- Deterministic sampling ---------------------------------------------

  # A float in [0, 1) per (floe, purpose), stateless so floe i's shape does
  # not depend on how many floes were sampled before it.
  rand =
    i: k:
    lib.fromHexString (builtins.substring 0 7 (builtins.hashString "sha256" "${seed}:${toString i}:${k}"))
    / 268435456.0;

  lerp =
    a: b: t:
    a + builtins.floor ((b - a) * t);

  # Piecewise quantiles: half at 1-5, to p90 at 16, a 0.5% tail to 170. The
  # middle bands are squared toward their low end, which is what brings the
  # mean to nixpkgs' 7.7 (15,519 options over 2,025 declaring files) without
  # moving the median or p90.
  weightOf =
    i:
    let
      u = rand i "w";
    in
    if u < 0.5 then
      lerp 1 6 (u / 0.5)
    else if u < 0.9 then
      lerp 6 17 (((u - 0.5) / 0.4) * ((u - 0.5) / 0.4))
    else if u < 0.995 then
      lerp 17 31 (((u - 0.9) / 0.095) * ((u - 0.9) / 0.095))
    else
      lerp 31 171 ((u - 0.995) / 0.005);

  # An input's type and default, the same `mkOption` on both sides: a floe's
  # inputs are native option types, so the declaration is shared verbatim.
  typeOf =
    i: k:
    let
      u = rand i "t${toString k}";
    in
    if u < 0.35 then
      {
        type = types.str;
        default = "v${toString k}";
      }
    else if u < 0.55 then
      {
        type = types.bool;
        default = true;
      }
    else if u < 0.70 then
      {
        type = types.port;
        default = 1000 + k;
      }
    else if u < 0.85 then
      {
        type = types.int;
        default = k;
      }
    else if u < 0.92 then
      {
        type = types.listOf types.str;
        default = [
          "a"
          "b"
        ];
      }
    else
      {
        type = types.attrsOf (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              port = mkOption { type = types.port; };
            };
          }
        );
        default.main = {
          name = "m";
          port = 80;
        };
      };

  optionsOf =
    i:
    lib.listToAttrs (
      lib.genList (
        k:
        lib.nameValuePair "o${toString k}" (
          mkOption (typeOf i k // { description = "Benchmark input ${toString k}."; })
        )
      ) (weightOf i)
    );

  # ---- Topology -------------------------------------------------------------

  # nixpkgs' namespaces, with the share of module-list.nix writing each.
  domains = [
    {
      d = "services";
      p = 0.67;
    }
    {
      d = "packages";
      p = 0.40;
    }
    {
      d = "users";
      p = 0.26;
    }
    {
      d = "groups";
      p = 0.26;
    }
    {
      d = "assertions";
      p = 0.24;
    }
    {
      d = "etc";
      p = 0.19;
    }
    {
      d = "firewall";
      p = 0.12;
    }
    {
      d = "warnings";
      p = 0.10;
    }
    {
      d = "tmpfiles";
      p = 0.08;
    }
    {
      d = "kernel";
      p = 0.04;
    }
  ];
  domainNames = map (x: x.d) domains;

  contributes =
    i:
    lib.concatLists (
      lib.imap0 (
        idx: x: lib.optional (if fanOut == null then rand i "c${x.d}" < x.p else idx < fanOut) x.d
      ) domains
    )
    ++ lib.optional (fault == "derived" && i == target && fanOut == null) "services";

  layer = i: lib.mod i (depth + 1);

  # 2-4 peers from the layer below, from a window of the 50 nearest, so a
  # floe's peers are plausibly related rather than uniformly anywhere.
  peersOf =
    i:
    let
      stride = depth + 1;
      span = lib.min 50 ((i - 1) / stride + 1);
      count = 2 + builtins.floor (3 * rand i "np");
    in
    if layer i == 0 || i < 1 then
      [ ]
    else
      lib.unique (lib.genList (t: i - 1 - stride * builtins.floor (span * rand i "p${toString t}")) count);

  # 1-3 domains read. `ports` is read only from one not contributed to, which
  # is what `T.derivedFrom` permits; the "derived" fault breaks exactly that.
  readsOf =
    i:
    lib.unique (
      lib.genList (t: lib.elemAt domainNames (builtins.floor (10 * rand i "r${toString t}"))) (
        1 + builtins.floor (3 * rand i "nr")
      )
      ++ lib.optional (fault == "derived" && i == target) "services"
    );
  readsPorts = i: d: !(lib.elem d (contributes i)) || (fault == "derived" && i == target);

  # The highest-layer unit with peers, which every fault is injected around.
  target = lib.findFirst (i: peersOf i != [ ]) 1 (lib.reverseList (lib.range 0 (n - 1)));

  # The provider the "missing" fault removes: the target's first peer.
  dropped = if fault == "missing" then lib.head (peersOf target) else null;

  hostOf = i: "s${toString i}.local";
  portOf = i: 1024 + lib.mod i 60000;

  # ---- The shared computation ----------------------------------------------
  #
  # Written once and called by both sides, so they cannot drift: given a
  # service's inputs, its peers' provides and the domains it reads, what it
  # claims into domain `d`.

  claimOf =
    i: d: inputs: peers: doms:
    {
      name = "s${toString i}";
      port = portOf i;
      enable = true;
      tags = [
        d
        "bench"
      ];
      settings = lib.mapAttrs (_: builtins.toJSON) inputs // {
        peers = lib.concatMapStrings (p: "${p.host}:${toString p.port},") peers;
        doms = lib.concatStrings (
          lib.mapAttrsToList (
            name: v: "${name}=${v.info}/${toString (lib.length (v.ports or [ ]))};"
          ) doms
        );
      };
    };

  claimFields = {
    name = T.str;
    port = T.port;
    enable = T.bool;
    tags = T.listOf T.str;
    settings = T.attrsOf T.str;
  };
  claimRec = T.record claimFields;

  foldPorts = claims: lib.sort (a: b: a < b) (lib.unique (lib.mapAttrsToList (_: c: c.port) claims));

  # ---- Floe side --------------------------------------------------------------

  SVC =
    i: retyped:
    floe.mkSig {
      name = "SVC_${toString i}";
      canonicalName = "p${toString i}";
      description = "Service ${toString i}'s endpoint.";
      fields = {
        host = T.str;
        port = if retyped then T.str else T.port;
      };
    };

  SVCX =
    i:
    floe.mkSig {
      name = "SVCX_${toString i}";
      canonicalName = "x${toString i}";
      description = "Service ${toString i}'s extra provide.";
      fields.url = T.str;
    };

  CLAIM = lib.genAttrs domainNames (
    d:
    floe.mkSig {
      name = "CLAIM_${d}";
      canonicalName = "claim_${d}";
      description = "A claim on the ${d} namespace.";
      fields = claimFields;
    }
  );

  DOM = lib.genAttrs domainNames (
    d:
    floe.mkSig {
      name = "DOM_${d}";
      canonicalName = "dom_${d}";
      description = "The ${d} namespace's owner.";
      fields = {
        info = T.str;
        ports = T.derivedFrom CLAIM.${d} (T.listOf T.port);
      };
    }
  );

  OUT =
    fields:
    floe.mkSig {
      name = "bench.config";
      canonicalName = "config";
      description = "The emitted configuration.";
      inherit fields;
    };

  # A service's claims are provides, one per domain it contributes to, so its
  # header names `CLAIM_<d>` for each and the domain's `collects` finds it.
  mkServiceFloe =
    i:
    let
      ds = contributes i;
      peerHoles = lib.listToAttrs (
        map (j: lib.nameValuePair "p${toString j}" (SVC j (fault == "retype" && i == target))) (peersOf i)
      );
      domHoles = lib.listToAttrs (map (d: lib.nameValuePair "dom_${d}" DOM.${d}) (readsOf i));
    in
    floe.mkFloe {
      name = "svc-${toString i}";
      summary = "Benchmark service ${toString i}.";
      inputs = optionsOf i;
      requires = peerHoles // domHoles;
      provides = {
        "p${toString i}" = SVC i false;
      }
      // lib.optionalAttrs (rand i "x" < 0.5) { "x${toString i}" = SVCX i; }
      // lib.listToAttrs (map (d: lib.nameValuePair "claim_${d}" CLAIM.${d}) ds);
      body =
        { inputs, requires, ... }:
        let
          peers = map (j: requires."p${toString j}") (peersOf i);
          doms = lib.listToAttrs (
            map (
              d:
              let
                v = requires."dom_${d}";
              in
              lib.nameValuePair d ({ inherit (v) info; } // lib.optionalAttrs (readsPorts i d) { inherit (v) ports; })
            ) (readsOf i)
          );
        in
        {
          provides = {
            "p${toString i}" = {
              host = hostOf i;
              port = portOf i;
            };
          }
          // lib.optionalAttrs (rand i "x" < 0.5) { "x${toString i}".url = "http://${hostOf i}"; }
          // lib.listToAttrs (map (d: lib.nameValuePair "claim_${d}" (claimOf i d inputs peers doms)) ds);
        };
    };

  mkDomain =
    d:
    floe.mkFloe {
      name = "dom-${d}";
      summary = "Owner of the ${d} namespace.";
      singleton = true;
      inputs.info = mkOption {
        type = types.str;
        default = "${d}-info";
        description = "What the namespace says about itself.";
      };
      collects."claim_${d}" = CLAIM.${d};
      provides."dom_${d}" = DOM.${d};
      out.config = OUT { ${d} = T.attrsOf claimRec; };
      body =
        { inputs, collects, ... }:
        {
          provides."dom_${d}" = {
            inherit (inputs) info;
            ports = foldPorts collects."claim_${d}";
          };
          out.config.${d} = collects."claim_${d}";
        };
    };

  services = lib.genList mkServiceFloe catalogue;

  # Unit names match the twin's claim keys, so the outputs compare equal.
  linked = lib.range 0 (n - 1);
  multi = lib.range 0 (n / 10 - 1);
  unitName = i: c: if c == 0 then "s${toString i}" else "s${toString i}-${toString c}";

  hostUnits =
    lib.listToAttrs (
      lib.concatMap (
        i:
        map (c: lib.nameValuePair (unitName i c) ((lib.elemAt services i).instantiate { })) (
          lib.range 0 ((if lib.elem i multi then instances else 1) - 1)
        )
      ) (lib.filter (i: i != dropped) linked)
    )
    // lib.listToAttrs (map (d: lib.nameValuePair "dom-${d}" ((mkDomain d).instantiate { })) domainNames)
    // lib.optionalAttrs (fault == "singleton") { dom-services-2 = (mkDomain "services").instantiate { }; };

  # A second instance makes every `SVC_i` it provides ambiguous; the link's
  # `defaults` names the first, which is the ceremony multi-instance costs.
  hostDefaults = lib.optionalAttrs (instances > 1) (
    lib.listToAttrs (map (i: lib.nameValuePair "SVC_${toString i}" (unitName i 0)) multi)
  );

  wrap =
    k: inner:
    (floe.mkFloe {
      name = "nest-${toString k}";
      summary = "Wraps the host link, level ${toString k}.";
      units = _: inner;
      defaults = if k == 1 then hostDefaults else { };
    }).instantiate
      { };

  floeLink =
    if nest <= 1 then
      floe.link {
        units = hostUnits;
        defaults = hostDefaults;
      }
    else
      floe.link {
        units = lib.foldl' (inner: k: { "n${toString k}" = wrap k inner; }) hostUnits (
          lib.range 1 (nest - 1)
        );
      };

  # ---- NixOS twin ----------------------------------------------------------

  twinService =
    i:
    { config, ... }:
    let
      cfg = config.svc."s${toString i}";
      peers = map (j: {
        inherit (config.svc."s${toString j}") host port;
      }) (peersOf i);
      doms = lib.genAttrs (readsOf i) (
        d:
        { inherit (config.dom.${d}) info; }
        // lib.optionalAttrs (readsPorts i d) { inherit (config.dom.${d}) ports; }
      );
      inputs = removeAttrs cfg [
        "enable"
        "host"
        "port"
      ];
    in
    {
      options.svc."s${toString i}" = optionsOf i // {
        enable = lib.mkEnableOption "service ${toString i}";
        host = mkOption {
          type = types.str;
          default = hostOf i;
        };
        port = mkOption {
          type = types.port;
          default = portOf i;
        };
      };
      config = lib.mkIf cfg.enable {
        dom = lib.genAttrs (contributes i) (d: {
          claims."s${toString i}" = claimOf i d inputs peers doms;
        });
      };
    };

  claimModule = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      port = mkOption { type = types.port; };
      enable = mkOption { type = types.bool; };
      tags = mkOption { type = types.listOf types.str; };
      settings = mkOption { type = types.attrsOf types.str; };
    };
  };

  twinDomain =
    d:
    { config, ... }:
    {
      options.dom.${d} = {
        info = mkOption {
          type = types.str;
          default = "${d}-info";
        };
        claims = mkOption {
          type = types.attrsOf claimModule;
          default = { };
        };
        ports = mkOption {
          type = types.listOf types.port;
          readOnly = true;
        };
      };
      options.out.${d} = mkOption { type = types.attrsOf types.unspecified; };
      config.dom.${d}.ports = foldPorts config.dom.${d}.claims;
      config.out.${d} = config.dom.${d}.claims;
    };

  twinFaults = {
    # Not imported, rather than disabled: a disabled NixOS module still
    # declares its options, so its peers read the defaults and nothing fails.
    missing = { };
    # The NixOS twin of a retyped field is a definition of the wrong type.
    retype.svc."s${toString (lib.head (peersOf target))}".port = "not-a-port";
    # A contributor reading the fold it contributes to. Not a fault here:
    # NixOS merges a submodule per option, so the fold reads every claim's
    # `port` and never the `settings` that read the fold. `link` refuses the
    # same read from headers, before anything evaluates, without asking
    # whether laziness would have carried it.
    derived = { };
    singleton = { };
  };

  twin = lib.evalModules {
    modules =
      map twinService (lib.filter (i: i != dropped) (lib.range 0 (catalogue - 1)))
      ++ map twinDomain domainNames
      ++ [
        {
          svc = lib.genAttrs (map (i: "s${toString i}") (lib.filter (i: i != dropped) linked)) (_: {
            enable = true;
          });
        }
      ]
      ++ lib.optional (fault != null) twinFaults.${fault};
  };

  # The adapter, which is what Q1(b) costs on top of the link: every fragment
  # handed to a NixOS core that owns each namespace's option type, the way
  # systemd owns `systemd.services`. So the floe side type-checks a claim
  # twice, sealed by `T` and merged by the core, and that is the real price
  # of the architecture rather than something to equalise away.
  adapted = lib.evalModules {
    modules = [
      {
        options.out = lib.genAttrs domainNames (
          _:
          mkOption {
            type = types.attrsOf claimModule;
            default = { };
          }
        );
      }
    ]
    ++ lib.mapAttrsToList (_: frag: { config.out = frag; }) floeLink.out."bench.config";
  };

  # The floe side's emitted output, merged the way an adapter would: each
  # domain owns its key, so a shallow union is the whole merge.
  floeOut = lib.foldl' (a: b: a // b) { } (lib.attrValues floeLink.out."bench.config");
in
{
  inherit
    floeLink
    floeOut
    twin
    target
    ;
  twinOut = twin.config.out;
  floeAdapted = adapted.config.out;

  meta = {
    units = lib.length (lib.attrNames hostUnits);
    catalogueInputs = lib.foldl' (a: i: a + weightOf i) 0 (lib.range 0 (catalogue - 1));
    signatures = catalogue + lib.length (lib.filter (i: rand i "x" < 0.5) (lib.range 0 (catalogue - 1))) + 2 * lib.length domains;
    fanIn = lib.genAttrs domainNames (
      d: lib.length (lib.filter (i: lib.elem d (contributes i)) linked)
    );
  };
}

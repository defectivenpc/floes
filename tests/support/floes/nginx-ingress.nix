# Provides INGRESS. Demonstrates: required input (baseDomain), defaulted
# input (className), a deferred provide (address), and out.k8s + out.meta.
{
  lib,
  floe,
  sigs,
  kinds,
}:

floe.mkFloe {
  name = "nginx-ingress";
  summary = "Fixture floe for a test suite.";

  inputs = {
    baseDomain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain all ingress hosts hang off. Required.";
    };
    className = lib.mkOption {
      type = lib.types.str;
      default = "nginx";
      description = "IngressClass name.";
    };
  };

  provides.ingress = sigs.INGRESS;
  out = {
    k8s = kinds.k8s;
    meta = kinds.meta;
  };

  modules = [
    ({ config, floe, ... }: {
      config.floe.provides.ingress = {
        baseDomain = config.floe.inputs.baseDomain;
        className = config.floe.inputs.className;
        # Not known until the LoadBalancer exists: emit a deferred token.
        address = floe.mkDeferred [
          "status"
          "loadBalancer"
          "ip"
        ];
      };

      config.floe.out.k8s.controller = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata.name = "ingress-nginx-controller";
      };

      config.floe.out.meta = {
        cluster = "public";
        environment = "lab";
      };
    })
  ];
}

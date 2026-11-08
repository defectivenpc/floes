# nixpkgs from `flake.lock`, so every number here names a revision rather than
# whatever `<nixpkgs>` resolves to on the machine that ran it.
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
in
builtins.fetchTree lock.nodes.nixpkgs.locked

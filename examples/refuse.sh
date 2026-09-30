#!/usr/bin/env bash
# The two failures no Nix test can hold.
#
# `builtins.tryEval` catches `throw` and `assert`, and nothing else — so a
# failure reported by Nix's own machinery rather than by floe takes the whole
# evaluation down with it, and `tests/examples.nix` cannot assert on it. Here a
# non-zero exit from `nix eval` is the assertion instead.
#
# Both cases are described in `examples/nixos/broken.nix`. The third deliberate
# mistake there, `leaky`, *is* a floe `throw` and is tested normally.
set -uo pipefail
cd "$(dirname "$0")/.."

force() {
  nix eval --impure --raw --expr "
    let
      lib = import <nixpkgs/lib>;
      floe = import ./lib { inherit lib; };
      ex = import ./examples/nixos { inherit lib floe; };
    in
    builtins.deepSeq ex.broken.$1.out \"reached\"
  " 2>&1
}

status=0
for case in interpolating greedy; do
  if out=$(force "$case"); then
    echo "FAIL: broken.$case evaluated and must not (got: $out)" >&2
    status=1
  else
    printf 'ok   broken.%-14s %s\n' "$case" \
      "$(printf '%s' "$out" | grep -m1 -oE 'error: [^$]*' | cut -c1-90)"
  fi
done

exit $status

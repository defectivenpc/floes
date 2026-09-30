#!/usr/bin/env bash
# Per-floe evaluation cost at scale, and a stock NixOS evaluation to compare
# against. A script and not a `nix flake check`: the numbers are for a human
# deciding what is affordable, and a machine-specific timing has no business
# failing a build.
#
#   ./bench/run.sh            # the sweep
#   ./bench/run.sh nixos      # the NixOS baseline alone
#
# Metrics are the evaluator's own (NIX_SHOW_STATS), not wall clock, so a busy
# machine perturbs them less. `gc_mb` is total bytes allocated over the whole
# evaluation, not peak residency.
#
# A failed `nix eval` still writes a stats file — holding the cost of parsing
# the expression that failed, which is small and plausible-looking. So every
# measurement here checks the exit status and prints FAILED rather than a
# number. A benchmark that silently reports the cost of a syntax error is worse
# than no benchmark.
set -euo pipefail
cd "$(dirname "$0")/.."

# eval_stats <nix-expr> -> "cpu_s gc_mb", or "FAILED FAILED"
eval_stats() {
  local f
  f=$(mktemp)
  if NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$f" \
       nix eval --impure --expr "$1" >/dev/null 2>&1; then
    jq -r '"\(.cpuTime) \(.gc.totalBytes / 1048576)"' "$f"
  else
    echo "FAILED FAILED"
  fi
  rm -f "$f"
}

# bench <nix-args> -> "cpu_s gc_mb"
bench() {
  eval_stats "import ./bench/link-scale.nix { $1; }"
}

nixos_baseline() {
  # Eval-only, so the target system need not be this one. Forced to the
  # toplevel derivation path, which is what `nixos-rebuild` computes.
  eval_stats '
    (import <nixpkgs/nixos/lib/eval-config.nix> {
      system = "x86_64-linux";
      modules = [{
        boot.loader.grub.devices = [ "/dev/sda" ];
        fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
        system.stateVersion = "24.05";
      }];
    }).config.system.build.toplevel.drvPath
  '
}

# row <label> <nix-args> [<baseline-cpu>]
# Prints the measurement, and the marginal per-floe cost when given a baseline.
row() {
  local label="$1" args="$2" base="${3:-}"
  read -r cpu gc < <(bench "$args")
  if [ "$cpu" = FAILED ]; then
    printf '%-26s FAILED\n' "$label"
    return 1
  fi
  local per="-"
  if [ -n "$base" ]; then
    per=$(awk -v c="$cpu" -v b="$base" 'BEGIN { printf "%.3f", c - b }')
  fi
  printf '%-26s %7.3f s  %6.0f MB  %s\n' "$label" "$cpu" "$gc" "$per"
}

if [ "${1:-}" = "nixos" ]; then
  read -r cpu gc < <(nixos_baseline)
  printf 'stock NixOS (minimal host): cpu %s s, allocated %.0f MB\n' "$cpu" "$gc"
  exit 0
fi

# The fixed cost: importing nixpkgs' lib and the floe library, no floes. Every
# per-floe figure below is marginal over this, at n=1000, so the "per" column
# reads directly as milliseconds per floe.
read -r base _ < <(bench 'n = 0; weight = 15; form = "body"')
printf 'fixed cost (n=0): %s s\n\n' "$base"

printf '%-26s %9s  %9s  %s\n' '' 'cpu' 'allocated' 'ms/floe'

echo '-- body form, at n=1000, 3 inputs each ------------------------'
row 'modules, trivial out'  'n = 1000; weight = 1;  form = "modules"' "$base"
row 'body,    trivial out'  'n = 1000; weight = 1;  form = "body"'    "$base"
row 'modules, realistic'    'n = 1000; weight = 15; form = "modules"' "$base"
row 'body,    realistic'    'n = 1000; weight = 15; form = "body"'    "$base"

echo
echo '-- what `checkInputs` costs (body form, realistic out) --------'
echo '   Validating what the deployer passed, via nixpkgs'"'"'                 '
echo '   `lib.modules.mergeDefinitions` per option. Separate from the'
echo '   floe body: a `modules` floe pays this *and* its own eval.'
row '0 inputs declared'  'n = 1000; weight = 15; form = "body"; withInputs = false' "$base"
row '3 inputs declared'  'n = 1000; weight = 15; form = "body"; inputCount = 3'     "$base"
row '15 inputs declared' 'n = 1000; weight = 15; form = "body"; inputCount = 15'    "$base"

echo
echo '-- scaling, body form, realistic out --------------------------'
for n in 1 10 100 400 1000 2000; do
  row "n = $n" "n = $n; weight = 15; form = \"body\"" ""
done

echo
echo '-- the two confounds, at n=400 -------------------------------'
echo '   `chain` decides how many holes the linker resolves; `fold`'
echo '   decides whether the values flowing through them grow.'
for chain in true false; do
  for fold in true false; do
    row "chain=$chain fold=$fold" \
      "n = 400; weight = 15; form = \"body\"; chain = $chain; fold = $fold" ""
  done
done

echo
read -r cpu gc < <(nixos_baseline)
printf 'stock NixOS (minimal host): cpu %s s, allocated %.0f MB\n' "$cpu" "$gc"

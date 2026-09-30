#!/usr/bin/env bash
# Per-floe evaluation cost at scale, and a stock NixOS evaluation to compare
# against. A script and not a `nix flake check`: the numbers are for a human
# deciding whether per-floe `evalModules` is affordable, and a machine-specific
# timing has no business failing a build.
#
#   ./bench/run.sh            # the sweep
#   ./bench/run.sh nixos      # the NixOS baseline alone
#
# Metrics are the evaluator's own (NIX_SHOW_STATS), not wall clock, so a busy
# machine perturbs them less. `gc_mb` is total bytes allocated over the whole
# evaluation, not peak residency.
set -euo pipefail
cd "$(dirname "$0")/.."

stats=$(mktemp)
trap 'rm -f "$stats"' EXIT

# eval_stats <nix-expr> -> "cpu_s gc_mb"
eval_stats() {
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$stats" \
    nix eval --impure --expr "$1" >/dev/null
  jq -r '"\(.cpuTime) \(.gc.totalBytes / 1048576)"' "$stats"
}

nixos_baseline() {
  # Eval-only, so the target system need not be this one. Forced to the
  # toplevel derivation path, which is what `nixos-rebuild` computes.
  eval_stats '
    (import <nixpkgs/nixos/lib/eval-config.nix> {
      system = "x86_64-linux";
      modules = [{
        boot.loader.grub.devices = [ "/dev/sda" ];
        fileSystems."/".device = "/dev/sda1";
        system.stateVersion = "24.05";
      }];
    }).config.system.build.toplevel.drvPath
  '
}

if [ "${1:-}" = "nixos" ]; then
  read -r cpu gc < <(nixos_baseline)
  printf 'stock NixOS (minimal host): cpu %.2fs, allocated %.0f MB\n' "$cpu" "$gc"
  exit 0
fi

printf 'weight\tn\tcpu_s\tgc_mb\tcpu_per_floe_ms\n'
for weight in 1 15; do
  for n in 0 1 10 100 400 1000; do
    read -r cpu gc < <(eval_stats \
      "import ./bench/link-scale.nix { n = $n; weight = $weight; }")
    # n=0 is the fixed cost of importing lib and the floe library; subtract it so
    # the per-floe figure is the marginal cost of one more floe.
    if [ "$n" = 0 ]; then base=$cpu; fi
    per=$(awk -v c="$cpu" -v b="$base" -v n="$n" \
      'BEGIN { if (n == 0) print "-"; else printf "%.2f", (c - b) * 1000 / n }')
    printf '%s\t%s\t%.3f\t%.0f\t%s\n' "$weight" "$n" "$cpu" "$gc" "$per"
  done
done

# The two confounds, held at realistic weight. `chain` decides how many holes
# the linker resolves; `fold` decides whether values flowing through them grow.
printf '\nchain/fold at weight 15, n=400\n'
for chain in true false; do
  for fold in true false; do
    read -r cpu gc < <(eval_stats \
      "import ./bench/link-scale.nix { n = 400; weight = 15; chain = $chain; fold = $fold; }")
    printf '  chain=%-5s fold=%-5s cpu %.3fs  gc %.0f MB\n' "$chain" "$fold" "$cpu" "$gc"
  done
done
echo
read -r cpu gc < <(nixos_baseline)
printf 'stock NixOS (minimal host): cpu %.2fs, allocated %.0f MB\n' "$cpu" "$gc"

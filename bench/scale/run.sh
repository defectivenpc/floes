#!/usr/bin/env bash
# Floes against a NixOS-module twin at nixpkgs' scale. `gen.nix` says what the
# two programs are; this measures them along one axis at a time from a
# nixpkgs-shaped host, then at two combined points, then with one mistake
# injected into the largest link.
#
#   ./bench/scale/run.sh            # everything
#   ./bench/scale/run.sh anchor     # the soundness check alone
#
# Every eval runs under an 8 GB cap and a 10-minute timeout, and hitting either
# prints OOM or TIMEOUT where the numbers would be: that is a result, the point
# on the axis where it broke, not a crash of this script.
#
# cpu and alloc are the evaluator's own (NIX_SHOW_STATS); alloc is bytes
# allocated over the run, not residency, which is what rss is. "exp" is the
# growth exponent of the marginal cpu over the axis's previous point, so 1.0
# is linear.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

# `time` is a shell keyword; GNU time is what reports peak RSS.
if ! command -v jq >/dev/null || ! type -P time >/dev/null; then
  exec nix shell nixpkgs#jq nixpkgs#time -c "$0" "$@"
fi
TIME=$(type -P time)

# measure <args> <target> -> "cpu alloc thunks calls rss" or a status word
measure() {
  local stats rss err status
  stats=$(mktemp) rss=$(mktemp) err=$(mktemp)
  # Through a file: systemd-run expands `${…}` in its arguments, which is
  # Nix's interpolation.
  local expr
  expr=$(mktemp --suffix=.nix)
  cat >"$expr" <<EOF
    let
      lib = import "\${import $ROOT/bench/scale/pinned.nix}/lib";
      g = import $ROOT/bench/scale/gen.nix ({ inherit lib; } // { $1; });
      l = g.floeLink;
      headers = [ l.cycles l.wiring l.graph ];
    in builtins.deepSeq ($2) true
EOF
  set +e
  timeout 600 systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
    env NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$stats" \
    "$TIME" -f %M -o "$rss" nix eval --impure --file "$expr" >/dev/null 2>"$err"
  status=$?
  set -e
  if [ $status -eq 0 ]; then
    jq -r --arg rss "$(tail -1 "$rss")" \
      '"\(.cpuTime) \(.gc.totalBytes / 1048576 | floor) \(.nrThunks) \(.nrFunctionCalls) \($rss | tonumber / 1024 | floor)"' "$stats"
  elif [ $status -eq 124 ]; then
    echo TIMEOUT
  elif grep -q 'Killed\|out of memory' "$rss" "$err" 2>/dev/null || [ $status -eq 137 ] || [ $status -eq 143 ]; then
    echo OOM
  else
    echo "FAILED: $(grep -m1 'error' "$err" | cut -c1-90)"
  fi
  rm -f "$stats" "$rss" "$err" "$expr"
}

header() {
  prevX=() prevC=()
  printf '\n%s\n' "-- $1 $(printf '%.0s-' $(seq 1 $((60 - ${#1}))))"
  printf '%-34s %8s %8s %11s %11s %7s %6s\n' '' cpu_s alloc_MB thunks calls rss_MB exp
}

# row <label> <args> <target> [<axis value> <base cpu>]
# Tracks the previous point per target so `exp` is local to one curve.
declare -A prevX prevC
row() {
  local label="$1" args="$2" target="$3" x="${4:-}" base="${5:-0}" r exp=-
  r=$(measure "$args" "$target")
  if [[ $r != [0-9]* ]]; then
    printf '%-34s %s\n' "$label" "$r"
    return
  fi
  read -r cpu alloc thunks calls rss <<<"$r"
  if [ -n "$x" ] && [ -n "${prevX[$target]:-}" ]; then
    exp=$(awk -v c="$cpu" -v b="$base" -v pc="${prevC[$target]}" -v x="$x" -v px="${prevX[$target]}" \
      'BEGIN { m = c - b; pm = pc - b; if (m > 0 && pm > 0) printf "%.2f", log(m / pm) / log(x / px); else print "-" }')
  fi
  [ -n "$x" ] && prevX[$target]=$x prevC[$target]=$cpu
  printf '%-34s %8.3f %8s %11s %11s %7s %6s\n' "$label" "$cpu" "$alloc" "$thunks" "$calls" "$rss" "$exp"
}

HEADERS='headers'
BODIES='headers ++ [ l.provides ]'
FULL='headers ++ [ l.provides g.floeOut ]'
ADAPTED='headers ++ [ l.provides g.floeOut g.floeAdapted ]'
TWIN='g.twinOut'

# ---- Soundness: the twin against stock NixOS ------------------------------
# The precondition for everything below: the twin's catalogue must cost what
# nixpkgs' does, within ±30%. Declarations only, because that is the layer
# under test: the rest of a stock eval is the core (systemd units, /etc,
# derivations), which floes' fragments land in through the adapter, so both
# sides pay it identically. It is printed as that constant, not compared.
STOCK='(import "${import '"$ROOT"'/bench/scale/pinned.nix}/nixos/lib/eval-config.nix" {
    system = "x86_64-linux";
    modules = [{
      boot.loader.grub.devices = [ "/dev/sda" ];
      fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
      system.stateVersion = "24.05";
    }];
  })'
anchor() {
  header 'anchor: the catalogue, stock NixOS vs the twin'
  row 'stock declarations (15.5k)' 'n = 0' "lib.length (lib.collect lib.isOption $STOCK.options)"
  row 'twin declarations' 'n = 0' 'lib.length (lib.collect lib.isOption g.twin.options)'
  row 'stock toplevel (core constant)' 'n = 0' "$STOCK.config.system.build.toplevel.drvPath"
  row 'twin, 50 enabled, output' 'n = 50' "$TWIN"
}

anchor
[ "${1:-}" = anchor ] && exit 0

# Fixed costs, subtracted before fitting an exponent: the floe side's is ten
# domains and no services; the twin's is the whole catalogue with nothing on.
read -r F0 _ < <(measure 'n = 0' "$FULL")
read -r W0 _ < <(measure 'n = 0' "$TWIN")
printf '\nfixed cost: floe %s s (n = 0), twin %s s (catalogue, nothing enabled)\n' "$F0" "$W0"

header 'breadth: units linked / modules enabled'
for n in 50 150 500 2000; do
  row "floe headers   n=$n" "n = $n" "$HEADERS" $n "$F0"
  row "floe +bodies   n=$n" "n = $n" "$BODIES" $n "$F0"
  row "floe full      n=$n" "n = $n" "$FULL" $n "$F0"
  row "floe +adapter  n=$n" "n = $n" "$ADAPTED" $n "$F0"
  row "twin           n=$n" "n = $n" "$TWIN" $n "$W0"
done

header 'fan-out: domains each unit claims into, n=500'
for f in 1 2 5 10; do
  row "floe full      fanOut=$f" "n = 500; fanOut = $f" "$FULL" $f "$F0"
  row "twin           fanOut=$f" "n = 500; fanOut = $f" "$TWIN" $f "$W0"
done

header 'requires depth, n=500'
for d in 1 5 20; do
  row "floe full      depth=$d" "n = 500; depth = $d" "$FULL" $d "$F0"
  row "twin           depth=$d" "n = 500; depth = $d" "$TWIN" $d "$W0"
done

header 'inclusion depth, n=500 (floe only)'
for k in 1 2 4 8; do
  row "floe headers   nest=$k" "n = 500; nest = $k" "$HEADERS" $k "$F0"
  row "floe full      nest=$k" "n = 500; nest = $k" "$FULL" $k "$F0"
done

header 'multi-instance, n=500 (floe only)'
for k in 1 10; do
  row "floe full      instances=$k" "n = 500; instances = $k" "$FULL" $k "$F0"
done

header 'combined'
row 'floe large host n=500' 'n = 500' "$FULL"
row 'floe large host +adapter' 'n = 500' "$ADAPTED"
row 'twin large host n=500' 'n = 500' "$TWIN"
EVERYTHING='n = 2000; fanOut = 10; nest = 4'
row 'floe everything headers' "$EVERYTHING" "$HEADERS"
row 'floe everything full' "$EVERYTHING" "$FULL"
row 'floe everything +adapter' "$EVERYTHING" "$ADAPTED"
row 'twin everything' 'n = 2000; fanOut = 10' "$TWIN"

# ---- The ceiling -------------------------------------------------------------
# Past nixpkgs, to find where each side stops: "everything" with a catalogue
# as large as the link, so the twin imports what the floe side links.
header 'ceiling: everything, catalogue = n'
for n in 2000 5000 10000 20000 50000; do
  row "floe +adapter  n=$n" "n = $n; catalogue = $n; fanOut = 10; nest = 4" "$ADAPTED" $n "$F0"
  row "twin           n=$n" "n = $n; catalogue = $n; fanOut = 10" "$TWIN" $n "$W0"
done

# ---- Faults, in the largest link -------------------------------------------
# The kill criterion is whether the first line names the offending unit, so
# that line is what gets printed, along with how long it took to arrive.
fault() {
  local side="$1" args="$2" target="$3" start err
  err=$(mktemp)
  start=$(date +%s.%N)
  timeout 600 nix eval --impure --expr "
    let
      lib = import \"\${import ./bench/scale/pinned.nix}/lib\";
      g = import ./bench/scale/gen.nix ({ inherit lib; } // { $args; });
      l = g.floeLink;
      headers = [ l.cycles l.wiring l.graph ];
    in builtins.deepSeq ($target) true" >/dev/null 2>"$err" && echo "  (no error)" >>"$err"
  # Nix prints the trace first and the message after the last `error:`.
  printf '%-20s %6.2f s  %6d chars  target s%s\n  > %s\n' "$side" \
    "$(awk -v a="$(date +%s.%N)" -v b="$start" 'BEGIN { print a - b }')" "$(awk '/^ *error:/ { m = "" } { m = m $0 } END { print length(m) }' "$err")" \
    "$(nix eval --impure --expr "(import ./bench/scale/gen.nix { lib = import \"\${import ./bench/scale/pinned.nix}/lib\"; $args; }).target")" \
    "$(grep -E '^ *error:|^  \(no error\)$' "$err" | tail -1 | sed 's/^ *//' | cut -c1-160)"
  rm -f "$err"
}

printf '\n-- faults, in the everything link %s\n' "$(printf '%.0s-' $(seq 1 27))"
for f in missing retype derived singleton; do
  fault "floe $f" "$EVERYTHING; fault = \"$f\"" "$FULL"
done
for f in missing retype derived; do
  fault "twin $f" "n = 2000; fanOut = 10; fault = \"$f\"" "$TWIN"
done

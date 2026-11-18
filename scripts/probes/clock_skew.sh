#!/usr/bin/env bash
#
# clock_skew.sh -- mj<->Jetson clock offset (ns) for latency_probe.py --skew-ns.
# Run FROM mj; it ssh's to the Jetson. SAMPLES=11 for a steadier median.
# Prints the median to stdout alone: SKEW=$(clock_skew.sh). See .docs/SCRIPTS.md.

set -uo pipefail

VEGA_SSH="${VEGA_USER:-dexmate}@${VEGA_HOST:-146.137.240.51}"
SSH_OPTS="-o ConnectTimeout=10"
SAMPLES="${SAMPLES:-5}"

if ! ssh $SSH_OPTS "$VEGA_SSH" true 2>/dev/null; then
    echo "-> ERROR: cannot ssh to $VEGA_SSH. Is the robot on and the key authorized?" >&2
    exit 1
fi

echo "-> Estimating mj<->Jetson clock offset over $SAMPLES round-trips ($VEGA_SSH)..." >&2
offsets=()
for i in $(seq 1 "$SAMPLES"); do
    t0=$(date +%s%N)
    t1=$(ssh $SSH_OPTS "$VEGA_SSH" 'date +%s%N' 2>/dev/null) || continue
    t2=$(date +%s%N)
    [[ -z "$t1" ]] && continue
    off=$(( ( (t1 - t0) + (t1 - t2) ) / 2 ))  # NTP-style, cancels symmetric ssh transit
    rtt=$(( t2 - t0 ))
    offsets+=("$off")
    printf "   sample %2d: offset=%+d ns  (%.2f ms)   rtt=%.1f ms\n" \
        "$i" "$off" "$(echo "$off/1000000" | bc -l)" "$(echo "$rtt/1000000" | bc -l)" >&2
done

if [[ ${#offsets[@]} -eq 0 ]]; then
    echo "-> ERROR: no successful samples." >&2
    exit 1
fi

IFS=$'\n' sorted=($(sort -n <<<"${offsets[*]}")); unset IFS
mid=$(( ${#sorted[@]} / 2 ))
if (( ${#sorted[@]} % 2 == 1 )); then
    median=${sorted[$mid]}
else
    median=$(( ( ${sorted[$((mid - 1))]} + ${sorted[$mid]} ) / 2 ))
fi

echo "" >&2
printf -- "-> median offset (Jetson - mj): %+d ns  (%.2f ms)\n" \
    "$median" "$(echo "$median/1000000" | bc -l)" >&2
echo "-> pass to a probe RUN ON THE JETSON:" >&2
echo "   python latency_probe.py --skew-ns $median" >&2
# stdout: just the number, so you can capture it: SKEW=$(./clock_skew.sh)
echo "$median"

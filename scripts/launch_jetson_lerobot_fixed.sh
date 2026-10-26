#!/usr/bin/env bash
#
# launch_jetson_lerobot_fixed.sh -- record variant 2: FIXED-TIME, hands-off.
# Driving stack AND lerobot-record run ON the Jetson (obs over the robot LAN, off the
# tunnel = higher rate); joycon_reader stays on mj. Each episode auto-advances after
# EPISODE_TIME_S (no interactive keys) -- best for headless batch collection. For
# end-early / re-record control use launch_jetson_lerobot_interactive.sh.
# Full rationale, chunking failsafe, and rsync-back: .docs/JETSON_RECORDING.md.
#
#   ./launch_jetson_lerobot_fixed.sh          # bring up the split stack, then record
#   ./launch_jetson_lerobot_fixed.sh record   # stack already up: just run the recorder
#   ./launch_jetson_lerobot_fixed.sh stop     # kill mj joycon + Jetson stack + sensors
#
# Configuration: scripts/jetson_record.env (shell / ../.env win over it).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_jetson_record_common.sh"

if [[ "${1:-}" == "stop" ]]; then
    stop_all
    exit 0
fi

RECORD_ONLY=false
[[ "${1:-}" == "record" || "${1:-}" == "record-only" ]] && RECORD_ONLY=true

jetson_record_preflight
[[ "$RECORD_ONLY" != "true" ]] && bring_up_split_stack

echo "-> Recording on the Jetson (fixed-time). Datasets land on the Jetson; pull cmd printed at the end."
run_record_session fixed

print_rsync_hint
echo "-> Done. Stop the stack with:  $0 stop"

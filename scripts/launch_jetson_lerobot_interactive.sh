#!/usr/bin/env bash
#
# launch_jetson_lerobot_interactive.sh -- record variant 3: TTY CONTROL (n/r/q).
# Like launch_jetson_lerobot_fixed.sh, but the recorder runs in the FOREGROUND of an
# `ssh -t` TTY for interactive episode control (lerobot's TerminalKeyListener, no custom
# shim). Keep the recorder terminal focused:
#   n = end episode early / next   r = re-record last   q = quit/stop (finalizes chunk)
# Episodes still auto-advance after EPISODE_TIME_S. Letters are used over arrows because
# arrow escapes split over SSH. Full rationale: .docs/JETSON_RECORDING.md.
#
#   ./launch_jetson_lerobot_interactive.sh          # bring up the split stack, then record
#   ./launch_jetson_lerobot_interactive.sh record   # stack already up: just run the recorder
#   ./launch_jetson_lerobot_interactive.sh stop     # kill mj joycon + Jetson stack + sensors
#
# Configuration: scripts/jetson_record.env (shared with the fixed-time variant).

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

echo "-> Recording on the Jetson (interactive TTY). Keep the recorder terminal focused."
run_record_session interactive

print_rsync_hint
echo "-> Done. Stop the stack with:  $0 stop"

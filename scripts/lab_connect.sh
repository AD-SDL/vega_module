#!/usr/bin/env bash
#
# lab_connect.sh
#
# Sets up the environment variables and SSH tunnel needed to talk to the
# Dexmate Vega-1 Pro from the MJ lab PC over the local lab network.
#
# The robot's Zenoh comm config (.dzcfg) is pinned to loopback (127.0.0.1:7447),
# so we forward a local port to the robot's Zenoh router via SSH. On the lab LAN
# the added latency is negligible.
#
# IMPORTANT: source this file (do not execute it) so the env vars persist in
# your current shell:
#
#     source lab_connect.sh
#
# Requirements (one-time):
#   - ~/.dexmate/comm/zenoh/dm_vg4e69870ce2-1p.dzcfg present
#   - SSH key authorized on the robot:  ssh-copy-id dexmate@146.137.240.51
#
# To tear the tunnel down later in the same shell:
#
#     vega_disconnect
#

# ---- Robot connection settings ----
export ROBOT_NAME="dm/vg4e69870ce2-1p"
export ZENOH_CONFIG="$HOME/.dexmate/comm/zenoh/dm_vg4e69870ce2-1p.dzcfg"
# Follower config: this robot has dexterous hands with touch sensors -> f5d6.
# Override before sourcing if you need a different end-effector variant.
#
# >>> HANDS DISABLED (2026-09-22): the F5D6 hands are not detected by the
# controller (query_hand_type() -> UNKNOWN), so dexcontrol disables the hand
# components and omniteleop's robot_controller.py crashes trying to open them.
# Using the no-hands variant (vega_1p) keeps arms/torso/head/chassis teleop and
# recording working. TO RE-ENABLE once the hands are detected again, restore:
#     export ROBOT_CONFIG="${ROBOT_CONFIG:-vega_1p_f5d6}"
# and revert the with_left_hand/with_right_hand flags in launch_exo_lerobot.sh.
# See HANDS_DISABLED.md in this repo.
export ROBOT_CONFIG="${ROBOT_CONFIG:-vega_1p}"
export ROBOT_IP="127.0.0.1"

# ---- Robot host on the lab LAN ----
VEGA_HOST="146.137.240.51"
VEGA_USER="dexmate"
ZENOH_PORT="7447"

# Open the SSH tunnel in the background if it is not already running.
# Forwards local 127.0.0.1:7447 to the robot's Zenoh router.
if nc -z 127.0.0.1 "$ZENOH_PORT" 2>/dev/null; then
    echo "Tunnel already active on 127.0.0.1:$ZENOH_PORT"
else
    echo "Opening SSH tunnel to $VEGA_USER@$VEGA_HOST (forwarding $ZENOH_PORT)..."
    ssh -f -N -L "${ZENOH_PORT}:localhost:${ZENOH_PORT}" "${VEGA_USER}@${VEGA_HOST}"
    sleep 2
    if nc -z 127.0.0.1 "$ZENOH_PORT" 2>/dev/null; then
        echo "Tunnel established on 127.0.0.1:$ZENOH_PORT"
    else
        echo "Tunnel failed to establish. Check that the robot is on and the SSH key works:"
        echo "  ssh ${VEGA_USER}@${VEGA_HOST} hostname"
    fi
fi

echo "Environment set:"
echo "  ROBOT_NAME   = $ROBOT_NAME"
echo "  ZENOH_CONFIG = $ZENOH_CONFIG"
echo "  ROBOT_CONFIG = $ROBOT_CONFIG"
echo "  ROBOT_IP     = $ROBOT_IP"
echo "Verify comms with:  dextop topic list"

# Helper to close the tunnel later in the same shell session.
vega_disconnect() {
    local pid
    pid=$(pgrep -f "ssh -f -N -L ${ZENOH_PORT}:localhost:${ZENOH_PORT} ${VEGA_USER}@${VEGA_HOST}")
    if [ -n "$pid" ]; then
        kill "$pid" && echo "Tunnel closed (pid $pid)."
    else
        echo "No matching tunnel process found."
    fi
}

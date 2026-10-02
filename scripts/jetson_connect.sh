#!/usr/bin/env bash
#
# jetson_connect.sh
#
# Environment for running the LeRobot stack DIRECTLY ON the Vega-1 Pro's onboard
# Thor Jetson (dexmate@146.137.240.51), as opposed to from mj or a laptop.
#
# The crucial difference from lab_connect.sh: there is NO SSH tunnel. The Zenoh
# router runs locally on this Jetson, so ROBOT_IP is plain loopback and the comm
# config is the .dzcfg already sitting in ~. Observations (head camera from the
# Nano, joint state on-box) never cross an external network -- this is the whole
# point of running the rollout here instead of over a tunnel.
#
# Source this (do NOT execute) so the vars persist in your shell:
#     source jetson_connect.sh
#
# Requirements on the Jetson (already true for the stock robot):
#   - ~/dm_vg4e69870ce2-1p.dzcfg present
#   - the robot's Zenoh router up (it is, as part of the normal dexcontrol stack)

# ---- Robot connection settings (identical namespace to lab_connect.sh) ----
export ROBOT_NAME="dm/vg4e69870ce2-1p"
# On the Jetson the comm config lives in the home dir, not ~/.dexmate/...
export ZENOH_CONFIG="${ZENOH_CONFIG:-$HOME/dm_vg4e69870ce2-1p.dzcfg}"
# Hands disabled (F5D6 undetected -> UNKNOWN). Same rationale as lab_connect.sh;
# see HANDS_DISABLED.md. Override before sourcing to change the EE variant.
export ROBOT_CONFIG="${ROBOT_CONFIG:-vega_1p}"
# Local Zenoh router -- no tunnel, no port forward.
export ROBOT_IP="127.0.0.1"

echo "Environment set (Jetson-local, no SSH tunnel):"
echo "  ROBOT_NAME   = $ROBOT_NAME"
echo "  ZENOH_CONFIG = $ZENOH_CONFIG"
echo "  ROBOT_CONFIG = $ROBOT_CONFIG"
echo "  ROBOT_IP     = $ROBOT_IP"
if [[ ! -f "$ZENOH_CONFIG" ]]; then
    echo "  WARNING: ZENOH_CONFIG not found at $ZENOH_CONFIG" >&2
fi

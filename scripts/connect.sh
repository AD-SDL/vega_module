#!/usr/bin/env bash
# connect.sh -- set up the robot env. Source (do NOT execute):
#     source connect.sh remote   # off-robot, opens an SSH tunnel (e.g. the MJ PC)
#     source connect.sh local    # on the robot's Jetson, loopback router, no tunnel
# Defaults to remote. Full detail: .docs/CONNECT.md.

_CONNECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CONNECT_DIR/_env.sh"
_load_env_file "$_CONNECT_DIR/../.env"
_load_env_file "$_CONNECT_DIR/connect.env"

CONNECT_TARGET="${1:-remote}"

export ROBOT_NAME ROBOT_CONFIG ROBOT_IP

case "$CONNECT_TARGET" in
    remote)
        export ZENOH_CONFIG="${ZENOH_CONFIG:-$(_expand_home "$REMOTE_ZENOH_CONFIG")}"
        if nc -z 127.0.0.1 "$ZENOH_PORT" 2>/dev/null; then
            echo "Tunnel already active on 127.0.0.1:$ZENOH_PORT"
        else
            echo "Opening SSH tunnel to $VEGA_USER@$VEGA_HOST (forwarding $ZENOH_PORT)..."
            ssh -f -N -L "${ZENOH_PORT}:localhost:${ZENOH_PORT}" "${VEGA_USER}@${VEGA_HOST}"
            sleep 2
            if nc -z 127.0.0.1 "$ZENOH_PORT" 2>/dev/null; then
                echo "Tunnel established on 127.0.0.1:$ZENOH_PORT"
            else
                echo "Tunnel failed. Check the robot is on and the SSH key works:" >&2
                echo "  ssh ${VEGA_USER}@${VEGA_HOST} hostname" >&2
            fi
        fi
        vega_disconnect() {
            local pid
            pid=$(pgrep -f "ssh -f -N -L ${ZENOH_PORT}:localhost:${ZENOH_PORT} ${VEGA_USER}@${VEGA_HOST}")
            if [ -n "$pid" ]; then
                kill "$pid" && echo "Tunnel closed (pid $pid)."
            else
                echo "No matching tunnel process found."
            fi
        }
        ;;
    local)
        export ZENOH_CONFIG="${ZENOH_CONFIG:-$(_expand_home "$LOCAL_ZENOH_CONFIG")}"
        ;;
    *)
        echo "connect.sh: unknown target '$CONNECT_TARGET' (expected 'remote' or 'local')" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

echo "Environment set ($CONNECT_TARGET):"
echo "  ROBOT_NAME   = $ROBOT_NAME"
echo "  ZENOH_CONFIG = $ZENOH_CONFIG"
echo "  ROBOT_CONFIG = $ROBOT_CONFIG"
echo "  ROBOT_IP     = $ROBOT_IP"
[[ -f "$ZENOH_CONFIG" ]] || echo "  WARNING: ZENOH_CONFIG not found at $ZENOH_CONFIG" >&2
echo "Verify comms with:  dextop topic list"

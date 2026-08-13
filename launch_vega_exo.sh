#!/bin/bash

RPL="rpl"

CMD1="echo '$RPL' | sudo -S chmod 666 /dev/ttyUSB0"
CMD2="source ~/venvs/dexmate/bin/activate"
CMD3="source ~/humanoids/vega_module/scripts/lab_connect.sh"
CMD4="cd ~/humanoids/omniteleop/"

LAUNCH_CMDS=(
    "python src/omniteleop/leader/joycon_reader.py --debug"
    "python src/omniteleop/leader/arm_reader.py --debug"
    "python src/omniteleop/follower/command_processor.py --debug"
    "python src/omniteleop/follower/robot_controller.py --debug --interpolation-method linear"
    "python src/omniteleop/record/mcap_recorder.py --debug"
    "python src/omniteleop/tools/telemetry_viewer.py"
)

sleep 5

for i in {0..5}; do
    FULL_CMD="$CMD1 && $CMD2 && $CMD3 && $CMD4 && ${LAUNCH_CMDS[$i]}; exec bash"
    gnome-terminal --title="Terminal $((i+1))" -- bash -c "$FULL_CMD"
done

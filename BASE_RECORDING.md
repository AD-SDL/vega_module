# Mobile-base recording: chassis + base cameras (2026-10-02)

Adds the **mobile base** and **base USB cameras** to the LeRobot dataset the exo teleop
records, on top of the stationary arms/torso/head schema. Lidar is **deferred**.

New recorded schema (vs the stationary `act_box_pickup`):

- **action** = joint `.pos` (arms/torso/head; hands currently off, see `HANDS_DISABLED.md`)
  **+ `base.vx` / `base.vy` / `base.wz`** (planar base velocity, from the teleop).
- **observation.state** = joint `.pos` **+ 4 chassis proprio** readbacks:
  `base.steer_left`, `base.steer_right`, `base.wheel_vel_left`, `base.wheel_vel_right`
  (raw swerve state from `chassis.steering_angle` / `chassis.wheel_velocity`, each `(2,)=[L,R]`;
  no odometry/kinematics).
- **observation.images** = head stereo (+ depth) **+ `base_back_camera` + `base_front_camera`**
  (640×480 RGB). Subset chosen after a rate spike: back clears 20 Hz comfortably; front is
  lighting-dependent (~12–14 Hz). Code supports all four base cams via `--robot.with_base_*_camera`.

This is a **new dataset + retrain** — not compatible with the stationary checkpoint.

## dexbot-utils fork (where the base cameras are declared)

The follower resolves its dexcontrol sensor config through
`RobotInfo.get_default_config("vega_1p")` → `dexbot_utils.configs.robots.vega_1p.Vega1pConfig`.
The stock 0.5.0 `sensors` dict has no base cameras, so `enable_sensor("base_front_camera")`
would `KeyError`. Fix:

- **Fork**: `/home/rpl/humanoids/dexbot-utils`, branch **`base-cameras`** off tag **`v0.5.0`**
  (matches the installed version). `pip install -e`'d into the dexmate venv
  (`/home/rpl/venvs/dexmate`) **over** the site-packages 0.5.0. `dexcontrol` pins only
  `dexbot-utils>=0.4.5`, so this satisfies it.
- **Edit**: 4 `CameraConfig` entries added to `Vega1pConfig.sensors` in
  `src/dexbot_utils/configs/robots/vega_1p.py` (base_front/back/left/right_camera, topic
  `sensors/<name>/rgb`, rtc `sensors/<name>/rgb_rtc`). They default `enabled=False`, so other
  dexcontrol clients are unaffected until the follower's `enable_sensor()` turns them on.
  `CameraConfig` → `USBCameraSensor` via `get_sensor_mapping()`.
- **Not yet done**: pushing to a GitHub fork remote (no `gh` on the box — add the remote and
  push the `base-cameras` branch by hand); installing the fork into the **Jetson** `rollout`
  conda env (only needed for base-aware *rollout*, not for recording on mj). Pin both machines
  to the same revision.

## Recording

`scripts/launch_exo_lerobot.sh` defaults `WITH_CHASSIS=true`,
`WITH_BASE_BACK_CAMERA=true`, `WITH_BASE_FRONT_CAMERA=true`, launches the two base cams via
`dexsensor`, and writes to `local/vega_exo_base` by default (give a unique `DATASET_REPO_ID`
per session — `NO_STAMP=true`). Set any of those env vars false to drop back toward the
stationary schema. Flags are set on BOTH `--robot` and `--teleop` so the action schemas match
(enforced by `check_exo_lerobot_contract.py`).

## Bring-up checks (robot up)

```bash
source scripts/lab_connect.sh
python scripts/check_exo_lerobot_contract.py                 # --with-chassis default true
python scripts/check_lerobot_recording.py --with-chassis \
    --with base_back_camera --with base_front_camera          # moves nothing, writes nothing
```

Then a short recording (drive the base with the JoyCon): confirm `action.base.vx/vy/wz` are
non-zero while driving and zero otherwise, and that 20 Hz holds. Single-writer safety is
unchanged: omniteleop stopped on mj for lerobot-driven motion checks;
`use_external_commands=true` for recording (follower observes, never commands the hardware).

## Files touched (all uncommitted — like the other vega patches; revert on reinstall)

- `dexbot-utils/src/dexbot_utils/configs/robots/vega_1p.py` (fork)
- `lerobot/src/lerobot/robots/vega_1p_follower/{config_,}vega_1p_follower.py`
- `lerobot/src/lerobot/teleoperators/vega_exo_joycon/{config_,}vega_exo_joycon.py`
- `vega_module/scripts/launch_exo_lerobot.sh`
- `vega_module/scripts/check_exo_lerobot_contract.py`, `check_lerobot_recording.py`

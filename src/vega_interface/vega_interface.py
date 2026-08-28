#!/usr/bin/env python3
"""
Dexmate Vega Interface
"""

import logging
import time
from typing import Any

import numpy as np
from dexbot_utils.configs import BaseRobotConfig
from dexcontrol.robot import Robot

logger = logging.getLogger(__name__)


def _jsonable(value: Any) -> Any:
    """Convert numpy scalars and arrays to Python for JSON serialization."""
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    return value


class Vega:
    """Interface to the Dexmate Vega 1 Pro."""

    def __init__(
        self,
        base_config: BaseRobotConfig | None = None,
    ) -> None:
        self.robot = Robot(configs=base_config)

    @property
    def is_connected(self) -> bool:
        """True while the Robot session is live."""
        return self.robot is not None and not self.robot.is_shutdown()

    def shutdown(self) -> None:
        """Shut down the robot session."""
        self.robot.shutdown()
        time.sleep(0.5)

    def components(self) -> list[str]:
        """Names of the present, enabled, controllable components."""
        return list(self.robot.get_controllable_component_map())

    def get_joint_positions(self) -> dict[str, dict[str, float]]:
        """Joint positions in (rads) grouped by component.

        Returns:
            e.g. ``{"left_arm": {"L_arm_j1": 0.0, ...}, "chassis": {...}}``.
            Components that fail to report are omitted rather than raising,
            since one silent component should not hide the rest.
        """
        positions: dict[str, dict[str, float]] = {}
        for name, component in self.robot.get_controllable_component_map().items():
            try:
                positions[name] = component.get_joint_pos_dict()
            except Exception as err:
                logger.warning("Could not read joint positions for %s: %s", name, err)
        return positions

    def get_joint_velocities(self) -> dict[str, dict[str, float]]:
        """Joint velocities in rad/s, grouped by component."""
        velocities: dict[str, dict[str, float]] = {}
        for name, component in self.robot.get_controllable_component_map().items():
            try:
                velocities[name] = component.get_joint_vel_dict()
            except Exception as err:
                logger.warning("Could not read joint velocities for %s: %s", name, err)
        return velocities

    # ------------------------------------------------------------------
    # Health - cheap, cached subscriber reads
    # ------------------------------------------------------------------

    def get_battery(self) -> dict[str, float]:
        """Battery percentage, temperature (C), current (A), voltage (V), power (W)."""
        return self.robot.battery.get_status()

    def get_estop(self) -> dict[str, bool]:
        """E-stop state.

        Returns:
            ``button_pressed`` and ``software_estop_enabled`` from the robot,
            plus ``data_active`` -- whether the e-stop topic is actually
            delivering updates. The vendor call cannot distinguish "not
            engaged" from "no data", so that third flag is what makes the
            other two trustworthy.
        """
        status: dict[str, bool] = dict(self.robot.estop.get_status())
        status["data_active"] = bool(self.robot.estop.is_active())
        return status

    def get_heartbeat(self) -> dict[str, Any]:
        """Heartbeat: is_active, last_value, time_since_last, timeout_seconds, enabled, paused."""
        return self.robot.heartbeat.get_status()

    def get_active_sensors(self) -> list[str]:
        """Names of the sensors currently reporting."""
        return self.robot.sensors.get_active_sensors()

    def is_estopped(self) -> bool:
        """True if the robot must not move.

        Fails CLOSED. ``EStop.get_status()`` reports both flags False when no
        message has arrived, which is indistinguishable from "not e-stopped",
        so a feed that is not delivering updates is treated as engaged rather
        than assumed safe.

        Raises:
            Whatever the e-stop component raises if it is absent entirely --
            the caller decides what an unreadable e-stop means.
        """
        estop = self.get_estop()
        if not estop["data_active"]:
            logger.warning(
                "E-stop feed is not delivering updates; treating as engaged. "
                "The robot will refuse to move until the feed recovers."
            )
            return True
        return bool(estop["button_pressed"] or estop["software_estop_enabled"])

    # ------------------------------------------------------------------
    # Aggregate - safe to call on a poll loop. Never raises.
    # ------------------------------------------------------------------

    def get_state(self) -> dict[str, Any]:
        """Full JSON-serializable snapshot of the robot.

        Every subsystem is guarded independently so one dead component
        degrades its own key rather than blanking the whole snapshot.

        Returns:
            dict with "connected", and when connected: "joints" (grouped by
            component), "battery", "estop", "heartbeat", and "sensors".
        """
        if not self.is_connected:
            return {"connected": False}

        state: dict[str, Any] = {"connected": True}

        try:
            state["joints"] = self.get_joint_positions()
        except Exception as err:
            logger.warning("Could not read joints: %s", err)

        for key, read in (
            ("battery", self.get_battery),
            ("estop", self.get_estop),
            ("heartbeat", self.get_heartbeat),
        ):
            try:
                state[key] = {k: _jsonable(v) for k, v in read().items()}
            except Exception as err:
                logger.warning("Could not read %s: %s", key, err)

        try:
            state["sensors"] = {"active": self.get_active_sensors()}
        except Exception as err:
            logger.warning("Could not read sensors: %s", err)

        return state

    # ------------------------------------------------------------------
    # On-demand only - NOT safe for the poll loop
    # ------------------------------------------------------------------

    def get_component_status(self) -> dict[str, Any]:
        """Whole-robot component health.

        Issues a blocking zenoh query, unlike the cached reads above. Call
        from an action, never from a poll loop.
        """
        return self.robot.get_component_status(show=False)

    def get_temperatures(self, component: str = "left_arm") -> dict[str, dict[str, float]]:
        """Motor/driver temperatures in C, keyed by joint name then source.

        The temperature subscriber auto-idles after 5s; polling this would
        keep it permanently awake. Call from an action, never from a poll loop.
        """
        return getattr(self.robot, component).temperature_sensor.get_temperatures()

    def get_wrench(self, side: str = "left") -> list[float]:
        """End-effector wrench ``[fx, fy, fz, tx, ty, tz]`` for one arm.

        Raises:
            RuntimeError: If no wrench sensor is fitted on that arm.
        """
        sensor = getattr(self.robot, f"{side}_arm").wrench_sensor
        if sensor is None:
            raise RuntimeError(f"No wrench sensor fitted on {side}_arm.")
        return _jsonable(sensor.get_wrench_state())

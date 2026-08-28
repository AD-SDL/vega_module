#!/usr/bin/env python3
"""REST node for the Dexmate Vega 1 Pro."""

from dexbot_utils.configs import BaseRobotConfig
from madsci.node_module.helpers import action
from madsci.node_module.rest_node_module import RestNode

from vega_interface.vega_interface import Vega
from vega_types import VegaNodeConfig


class VegaNode(RestNode):
    """Dexmate Vega 1 Pro module

    This node provides a REST API for controlling the vega device.
    """

    vega: Vega | None = None
    config: VegaNodeConfig = VegaNodeConfig()
    config_model = VegaNodeConfig

    def __init__(
        self,
        base_config: BaseRobotConfig | None = None,
        **kwargs,
    ) -> None:
        self.base_config = base_config
        super().__init__(**kwargs)

    def startup_handler(self) -> None:
        """Called to (re)initialize the node. Connects to the robot."""
        if self.config.interface_type == "fake":
            raise NotImplementedError("TBD")  # ***
        self.vega = Vega(base_config=self.base_config)
        self.logger.log_info("Vega Node initialized.")

    def shutdown_handler(self) -> None:
        """Called to shutdown the node. Closes the robot session."""
        try:
            if self.vega is not None:
                self.vega.shutdown()
                self.vega = None
        except Exception as err:
            self.logger.log_error(f"Error shutting down the Vega Node: {err}")
            raise err

    def state_handler(self) -> None:
        """Periodically called to update the current state of the node."""
        if self.vega is not None:
            try:
                self.node_state = self.vega.get_state()
            except Exception as err:
                self.logger.log_error(f"Error reading Vega state: {err}")

    def status_handler(self) -> None:
        """Periodically called to update node status. Node stopped when either e-stopped or reading fails."""
        if self.vega is not None:
            try:
                self.node_status.stopped = self.vega.is_estopped()
            except Exception as err:
                self.logger.log_error(f"Could not read Vega e-stop, holding node stopped: {err}")
                self.node_status.stopped = True

    @action(
        name="get_joint_positions",
        description="Read current joint positions (rads) by component.",
    )
    def get_joint_positions(self) -> dict:
        """Return joint positions by component then joint name."""
        return self.vega.get_joint_positions()

    @action(
        name="get_component_status",
        description="Full component health report. Issues a blocking query to the robot.",
    )
    def get_component_status(self) -> dict:
        """Return the whole-robot component health report. Blocking request, do not poll."""
        return self.vega.get_component_status()


if __name__ == "__main__":
    vega1p = VegaNode()
    vega1p.start_node()

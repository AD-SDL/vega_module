# Dexmate Vega + LeRobot Integration

Dexmate Vega 1 Pro module

## Installation
### 1. Install the `omniteleop' fork
Currently, `omniteleop` lists `dexstream` as an optional dependency, but `leader/__init__.py` makes it essentially required.
Either install `dexstream` following the instructions on https://github.com/dexmate-ai/dexstream to be able to install `omniteleop` normally, or install the fork which guards against the import.
```python
# In your project directory clone the omniteleop fork.
git clone https://github.com/AileenCleary/omniteleop.git # Change to ADSDL fork.
cd omniteleop

# Install with pip in a virtual environment (recommended).
pip install -e .

cd ..
```


## LeRobot Integration

### Teleoperation (Exoskeleton)
#### `Vega1PFollowerConfig`
##### `lerobot/src/lerobot/robots/vega_1p/config_vega_1p_follower.py`
`Vega1PFollowerConfig` contains the user-specified configuration parameters of this specific instance of the robot (follower).
Ensure the class attributes agree with your `Vega1PFollowerConfig` and actual robot hardware, and change parameters to match your needs and preferences.

Important Attributes
| Attribute | Type | Description | 
| ------------- | ------------- | ------------- |
| `*_with` | `bool` | Follower feature key flags indicating which robot components and sensors to command and record. Must match `Vega1PFollowerConfig` flags and agree with Dexcontrol config files. |
| `use_external_commands` | `bool = False` | Whether to drive Vega internally (LeRobot) or externally (omniteleop; teleoperation). |

#### `VegaExoJoyconConfig`
##### `lerobot/src/lerobot/teleoperators/vega_exo_joycon/config_vega_exo_joycon.py`
`VegaExoJoyconConfig` contains the user-specified configuration parameters of this specific instance of the teleoperator.
Ensure the class attributes agree with your `Vega1PFollowerConfig` and actual robot hardware, and change parameters to match your needs and preferences.

Important Attributes
| Attribute | Type | Description | 
| ------------- | ------------- | ------------- |
| `*_with` | `bool` | Teleoperator action key flags indicating which robot components to include. Must match `Vega1PFollowerConfig` flags. |
| `connect_timeout_s` | `float = 120.0` | How long 'connect()' will wait for the first command message to be published. `omniteleop` blocks motion behind an `exo/robot_alignment` check AND a fresh e-stop release, so specific to operator needs. |
| `max_command_age_s` | `float = 0.5` | The maximum time in seconds allowed between command messages. A command older than this indicates that Zenoh has stopped publishing. The `command_rate` is 20 Hz -> 20 messages per second -> 1 message every 0.05 seconds. So if `max_command_age_s`= 0.5 seconds -> 0.5/0.05 = ~10 missed messages. | 

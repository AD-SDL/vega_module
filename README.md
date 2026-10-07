# Dexmate Vega + LeRobot Integration

Dexmate Vega 1 Pro module

## Installation
### 1. Install the `omniteleop' fork
Currently, `omniteleop` lists `dexstream` as an optional dependency, but `leader/__init__.py` makes it essentially required.
Either install `dexstream` following the instructions on https://github.com/dexmate-ai/dexstream to be able to install `omniteleop` normally, or install the fork which guards against the import.
```python
# In your project directory clone the omniteleop fork.
git clone https://github.com/AileenCleary/omniteleop.git # Change to AD-SDL fork.
cd omniteleop

# Install with pip in a virtual environment (recommended).
pip install -e .

cd ..
```

### 2. Install the `dexbot-utils' fork
Recent updates to Dexmate's `dexbot-utils` Github Repository have converted the entire library to be Rust-based instead of Python. Our alternative fork maintains Python as the primary language, which allows us to locally modify the robot configuration files that `dexcontrol` uses to construct the config. We use this to add and enable the four base cameras (front, back, right, left) located in the chassis. 

The Rust-based version has no reference to these sensors, and adding them would require installing additional tools. For now, the simplest solution is to temporarily continue with the Python-based framework in this fork, until another library requires the updated Rust version of `dexbot-utils` or additional sensors are added to the configuration files by Dexmate themselves.
```python
# In your project directory clone the dexbot-utils fork.
git clone https://github.com/AileenCleary/dexbot-utils.git # Change to AD-SDL fork.
cd omniteleop

# Checkout the Python-based `base-cameras` branch.
git checkout base-cameras

# Install with pip in a virtual environment (recommended).
pip install -e .

cd ..
```

### 3. Install the `lerobot' fork
Our `lerobot` fork adds the Dexmate Vega 1 Pro and the JoyCon Exoskeleton Teleoperator to the list of robots/teleoperators currently supported by LeRobot.
```python
# In your project directory clone the AD-SDL lerobot fork.
git clone https://github.com/AD-SDL/lerobot.git
cd lerobot

# Checkout the Vega 1 Pro branch.
git checkout vega_1p

# Install with pip in a virtual environment (recommended).
pip install -e .
```
This module requires some additional `lerobot` extras to enable full functionality. Run these commands from the same `lerobot` repository.
```python
# For dataset recording + editing (minimum required extras).
pip install -e '.[dataset,hardware]'

# If you'll also be training policies on this machine, add `training`.
pip install -e '.[dataset,hardware,training]'

# For convenience (`core_scripts`=`training`+`dataset`+`viz`).
pip install -e '.[core_scripts,training]'
```

### 4. Install the `dexcontrol' fork
Dexmate is currently in the process of also converting dexcontrol to (accomodate) Rust. This fork and branch preserve the original mostly Python-only framework, which is needed to work with our `dexbot-utils` fork. This is likely a temporary solution until Dexmate releases a stable version of the repository with the Rust updates and a comprehensive update can be made to our own repositories to successfully integrate with the newest library versions.
```python
# In your project directory clone the dexcontrol fork.
git clone https://github.com/AileenCleary/dexcontrol.git # Change to AD-SDL fork.
cd dexcontrol

# Switch to the Python-based branch.
git checkout ad-sdl

# Install with pip in a virtual environment (recommended).
pip install -e .

cd ..
```
## LeRobot Integration

### Teleoperation (Exoskeleton)
#### `Vega1PFollowerConfig`
##### `lerobot/src/lerobot/robots/vega_1p/config_vega_1p_follower.py`
`Vega1PFollowerConfig` contains the user-specified configuration parameters of this specific instance of the robot (follower).
Ensure the class attributes agree with your `VegaExoJoyconConfig` and actual robot hardware, and change parameters to match your needs and preferences.

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

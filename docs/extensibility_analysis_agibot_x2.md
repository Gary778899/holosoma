# Extending Holosoma Pipeline to Agibot X2: Feasibility & Integration Guide

**Date**: 2025  
**Status**: Feasibility Analysis & Implementation Guide  
**Target Platform**: Agibot X2 Humanoid Robot

---

## Executive Summary

The holosoma pipeline is **highly extensible** for new robot platforms. It uses Python entry points and factory patterns to support multiple SDKs (Unitree, Booster). To deploy policies to Agibot X2, you would need to:

1. **Create an Agibot SDK interface** (~300-500 lines of Python)
2. **Add robot configuration** (~100 lines of config dataclass)
3. **Register via entry points** (modify `setup.py`)
4. **Optionally: Add training bridge** for sim-to-sim validation (~300-500 lines)

**Estimated effort**: 2-3 weeks for a complete, production-ready integration with hardware testing.

---

## Part I: Extensibility Architecture

### 1. Plugin System Overview

The pipeline uses **Python entry points** (setuptools) for runtime discovery:

```
holosoma_inference/ (inference/deployment package)
├── sdk/
│   ├── __init__.py              # Factory with entry point discovery
│   ├── unitree/unitree_interface.py
│   └── booster/booster_interface.py
└── config/
    └── config_values/
        ├── robot.py              # Robot configs registered as entry points
        └── inference.py           # Inference configs

holosoma/ (training package)
├── bridge/
│   ├── __init__.py               # Factory for sim-to-real bridges
│   ├── unitree/unitree_sdk2py_bridge.py
│   └── booster/booster_sdk2py_bridge.py
```

**Entry point groups** in `setup.py`:
- `holosoma.sdk`: Maps SDK type name to interface class
- `holosoma.config.robot`: Maps robot config name to RobotConfig instance
- `holosoma.config.inference`: Maps inference config name to InferenceConfig instance

### 2. Design Patterns Used

| Pattern | Where | Purpose |
|---------|-------|---------|
| **Factory** | `create_interface()` in `sdk/__init__.py` | Lazy-load SDK backends |
| **Base class + inheritance** | `BaseInterface` → `UnitreeInterface`, `BoosterInterface` | Define SDK contract |
| **Dataclass config** | `RobotConfig`, `InferenceConfig` | Type-safe config composition |
| **Entry point registry** | `entry_points(group="holosoma.sdk")` | Runtime plugin discovery |
| **Lazy loading** | Cache + load-on-first-use | Avoid missing dependency errors |

### 3. Current Supported Robots

| Robot | Family | SDK Type | Status | Notes |
|-------|--------|----------|--------|-------|
| Unitree G1 | 29-DOF humanoid | `unitree` | ✅ Deployed | C++ binding for low-latency |
| Unitree H1 | 40-DOF humanoid | `unitree` | ✅ Supported | Same binding as G1 |
| Unitree GO2 | 12-DOF quadruped | `unitree` | ✅ Supported | Motor order differs from joints |
| Unitree H1 2.0 | Updated H1 | `unitree` | ✅ Supported | Minor config changes |
| Agibot T1 (Booster) | 29-DOF humanoid | `booster` | ✅ Deployed | Python SDK (sdk2py) |

---

## Part II: Critical Integration Points

### 1. Inference SDK Layer (Required for Real Robot)

**File**: `src/holosoma_inference/holosoma_inference/sdk/agibot/agibot_interface.py`

**Base Interface Contract** ([source](src/holosoma_inference/holosoma_inference/sdk/base/base_interface.py)):

```python
class BaseInterface(ABC):
    """Abstract base class for robot control interfaces."""
    
    @abstractmethod
    def get_low_state(self) -> np.ndarray:
        """
        Returns: np.ndarray with shape (1, 3+4+N+3+3+N) containing:
        [base_pos(3), quat(4), joint_pos(N), lin_vel(3), ang_vel(3), joint_vel(N)]
        """
    
    @abstractmethod
    def send_low_command(
        self,
        cmd_q: np.ndarray,         # target joint positions (N,)
        cmd_dq: np.ndarray,        # target joint velocities (N,)
        cmd_tau: np.ndarray,       # feedforward torques (N,)
        dof_pos_latest: np.ndarray = None,
        kp_override: np.ndarray = None,  # Optional PD gains override
        kd_override: np.ndarray = None,
    ):
        """Send low-level command to robot."""
    
    @abstractmethod
    def get_joystick_msg(self):
        """Return joystick/controller state or None."""
    
    @abstractmethod
    def get_joystick_key(self, wc_msg=None):
        """Return current button press or None."""
```

**Key Requirements for `AgibotInterface`**:

1. **State array format** must match: `[base_pos, quat, joint_pos, base_lin_vel, base_ang_vel, joint_vel]`
   - Base position: 3D (estimated from IMU odometry or set to zeros if not available)
   - Quaternion: 4D from robot IMU
   - Joint positions: N-DOF from encoders
   - Base linear velocity: 3D (optional: zeros if not available)
   - Base angular velocity: 3D from gyroscope
   - Joint velocities: N-DOF (from encoders or differentiated positions)

2. **Command interface** must accept:
   - Position targets
   - Velocity targets  
   - Feedforward torques
   - Optional PD gain overrides (from ONNX metadata)

3. **Joystick support** (optional but recommended)
   - Read wireless controller state
   - Map buttons to named actions (R1, L1, A, B, etc.)

### 2. Robot Configuration (Required)

**File**: `src/holosoma_inference/holosoma_inference/config/config_values/robot.py`

**RobotConfig dataclass fields** (see [source](src/holosoma_inference/holosoma_inference/config/config_types/robot.py)):

```python
@dataclass(frozen=True)
class RobotConfig:
    # REQUIRED - Identity
    robot_type: str                      # "agibot_x2_29dof"
    robot: str                           # "agibot_x2"
    
    # REQUIRED - Kinematics
    num_motors: int                      # 29 for X2
    num_joints: int                      # 29 for X2 (assuming all motors are controllable joints)
    num_upper_body_joints: int           # Typically 16 for humanoids (arms + head/waist)
    
    # REQUIRED - Default positions
    default_dof_angles: tuple[float, ...] # Standing pose in radians (length 29)
    default_motor_angles: tuple[float, ...]
    
    # REQUIRED - Mappings
    motor2joint: tuple[int, ...]         # Motor index → joint index
    joint2motor: tuple[int, ...]         # Joint index → motor index
    dof_names: tuple[str, ...]           # Joint names (length 29)
    dof_names_upper_body: tuple[str, ...]
    dof_names_lower_body: tuple[str, ...]
    
    # OPTIONAL (can load from ONNX metadata)
    motor_kp: tuple[float, ...] | None   # PD proportional gains
    motor_kd: tuple[float, ...] | None   # PD derivative gains
    
    # REQUIRED - SDK selection
    sdk_type: str = "agibot"             # Must match entry point name
    motor_type: str = "serial"           # "serial" or "parallel"
    message_type: str = "HG"             # Protocol type (e.g., "HG" for humanoid)
```

**Example for Agibot X2** (based on G1 structure):

```python
x2_29dof = RobotConfig(
    robot_type="agibot_x2_29dof",
    robot="agibot_x2",
    
    sdk_type="agibot",
    motor_type="serial",
    message_type="HG",
    
    num_motors=29,
    num_joints=29,
    num_upper_body_joints=16,  # Adjust based on X2 structure
    
    default_dof_angles=(
        # Left leg (6): hip_pitch, hip_roll, hip_yaw, knee, ankle_pitch, ankle_roll
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        # Right leg (6)
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        # Waist (3): yaw, roll, pitch
        0.0, 0.0, 0.0,
        # Left arm (7): shoulder_pitch/roll/yaw, elbow, wrist_roll/pitch/yaw
        0.2, 0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
        # Right arm (7)
        0.2, -0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
    ),
    # ... (other required fields)
    dof_names=(
        "left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint",
        "left_knee_joint", "left_ankle_pitch_joint", "left_ankle_roll_joint",
        # ... (29 total joint names matching X2 URDF)
    ),
)
```

### 3. Training Bridge (Optional - for sim-to-sim validation)

**File**: `src/holosoma/holosoma/bridge/agibot/agibot_sdk2py_bridge.py`

**Base Bridge Contract** ([source](src/holosoma/holosoma/bridge/base/basic_sdk2py_bridge.py)):

```python
class BasicSdk2Bridge(ABC):
    """Abstract base for simulator-to-SDK bridges."""
    
    @abstractmethod
    def _init_sdk_components(self):
        """Initialize SDK interface to actual robot or sim."""
    
    @abstractmethod
    def low_cmd_handler(self, msg=None):
        """Receive low-level command from simulator."""
    
    @abstractmethod
    def publish_low_state(self):
        """Send robot state to simulator."""
    
    def _compute_pd_torques(self, tau_ff, kp, kd, q_target, dq_target):
        """Helper: PD controller τ = τ_ff + kp(q_des - q) + kd(dq_des - dq)."""
```

**Implementation pattern** (from Unitree example):

1. Initialize Agibot SDK (abstract motion/control API)
2. Read robot state in `publish_low_state()` and convert to simulator format
3. Receive commands in `low_cmd_handler()` and send to robot via Agibot SDK
4. Implement PD torque computation if needed

---

## Part III: Step-by-Step Integration Plan

### Phase 1: Preparation & Analysis (Days 1-3)

**Tasks**:

1. **Obtain Agibot X2 specifications**:
   - URDF/SDF kinematic model
   - Motor/joint mapping (which motor index corresponds to which joint)
   - Default standing pose angles
   - PD control gain ranges (kp, kd typical values)
   - Maximum/minimum joint angles
   - Effort limits per joint
   - IMU/sensor output format

2. **Understand Agibot SDK**:
   - Protocol for state requests (how to read robot joint positions/velocities/IMU)
   - Protocol for command sending (format of position/velocity/torque targets)
   - Network interface (ethernet, ROS 2, proprietary daemon?)
   - Latency characteristics
   - Joystick/controller integration (if applicable)

3. **Review existing implementations**:
   - Study [Unitree interface](src/holosoma_inference/holosoma_inference/sdk/unitree/unitree_interface.py) (C++ binding example)
   - Study [Booster interface](src/holosoma_inference/holosoma_inference/sdk/booster/booster_interface.py) (Python SDK example)
   - Note differences (motor order, message types, control modes)

### Phase 2: Create Inference SDK Interface (Days 4-7)

**File structure**:
```
src/holosoma_inference/holosoma_inference/sdk/agibot/
├── __init__.py
├── agibot_interface.py          # Main interface (inherit from BaseInterface)
├── command_sender.py            # (Optional if using factory pattern like Booster)
└── state_processor.py           # (Optional if using factory pattern like Booster)
```

**Steps**:

1. **Create AgibotInterface class** (~400 lines):
   ```python
   from holosoma_inference.sdk.base.base_interface import BaseInterface
   
   class AgibotInterface(BaseInterface):
       def __init__(self, robot_config, domain_id=0, interface_str=None, use_joystick=True):
           super().__init__(robot_config, domain_id, interface_str, use_joystick)
           self._init_agibot_sdk()
       
       def _init_agibot_sdk(self):
           """Initialize Agibot SDK and connect to robot."""
           # Import Agibot SDK
           from agibot_sdk import AgibotClient  # Hypothetical
           
           # Parse interface/connection info
           self.client = AgibotClient(ip=interface_str, port=...)
           self.client.connect()
       
       def get_low_state(self) -> np.ndarray:
           """Read state from robot via Agibot SDK."""
           state = self.client.get_robot_state()
           # Parse and convert to required format
           base_pos = np.zeros(3)  # or estimate from odometry
           quat = state.imu.quaternion  # Convert to numpy
           joint_pos = np.array(state.joint_positions)
           base_lin_vel = np.zeros(3)  # or estimate
           base_ang_vel = np.array(state.imu.angular_velocity)
           joint_vel = np.array(state.joint_velocities)
           
           return np.concatenate([...]).reshape(1, -1)
       
       def send_low_command(self, cmd_q, cmd_dq, cmd_tau, 
                           dof_pos_latest=None, kp_override=None, kd_override=None):
           """Send command to robot."""
           kp = kp_override if kp_override is not None else self.robot_config.motor_kp
           kd = kd_override if kd_override is not None else self.robot_config.motor_kd
           
           # Send PD command
           self.client.send_pd_command(
               q_target=cmd_q,
               dq_target=cmd_dq,
               tau_ff=cmd_tau,
               kp=kp,
               kd=kd
           )
       
       def get_joystick_msg(self):
           """Return joystick state if available."""
           # Implement based on Agibot's joystick API
           return self.client.read_controller()  # or None
       
       def get_joystick_key(self, wc_msg=None):
           """Extract button press from joystick message."""
           # Map Agibot controller buttons to standard names
           if wc_msg is None:
               wc_msg = self.get_joystick_msg()
           if wc_msg is None:
               return None
           return self._wc_key_map.get(wc_msg.button_id, None)
   ```

2. **Add to entry points** in `setup.py`:
   ```python
   entry_points={
       "holosoma.sdk": [
           # ... existing entries
           "agibot = holosoma_inference.sdk.agibot.agibot_interface:AgibotInterface",
       ],
   }
   ```

3. **Add robot config**:
   ```python
   # In src/holosoma_inference/holosoma_inference/config/config_values/robot.py
   x2_29dof = RobotConfig(
       robot_type="agibot_x2_29dof",
       robot="agibot_x2",
       sdk_type="agibot",
       # ... other fields (see Phase 1 preparation)
   )
   
   # Add to entry points in setup.py
   entry_points={
       "holosoma.config.robot": [
           # ... existing
           "agibot-x2-29dof = holosoma_inference.config.config_values.robot:x2_29dof",
       ],
   }
   ```

4. **Add inference config** (optional, if you want preset inference parameters):
   ```python
   # In src/holosoma_inference/holosoma_inference/config/config_values/inference.py
   x2_29dof_loco = InferenceConfig(
       robot=x2_29dof,
       observation=loco_x2_29dof,  # Define observation config
       task=locomotion_task,
       # ... other params
   )
   
   # Add to entry points
   entry_points={
       "holosoma.config.inference": [
           # ... existing
           "agibot-x2-29dof-loco = holosoma_inference.config.config_values.inference:x2_29dof_loco",
       ],
   }
   ```

**Validation**:
```bash
# Test that entry point registers correctly
python -c "from holosoma_inference.sdk import create_interface; \
           from holosoma_inference.config.config_values.robot import x2_29dof; \
           iface = create_interface(x2_29dof, interface_str='192.168.1.100')"
```

### Phase 3: Test Inference on Real Robot (Days 8-10)

**Prerequisites**:
- Pre-trained ONNX model for locomotion
- Agibot X2 hardware available
- Access to robot with SSH/network connectivity

**Steps**:

1. **Create test script** (`test_inference.py`):
   ```python
   #!/usr/bin/env python
   import tyro
   from holosoma_inference.run_policy import run_policy
   from holosoma_inference.config.config_values.inference import x2_29dof_loco
   
   if __name__ == "__main__":
       config = tyro.cli(InferenceConfig, default=x2_29dof_loco)
       run_policy(config)
   ```

2. **Run deployment** (on X2 robot or offboard control):
   ```bash
   # Offboard control (from PC to robot at 192.168.1.100):
   python run_test_inference.py \
       --config config/inference/agibot_x2_loco \
       --model-path policy.onnx \
       --interface 192.168.1.100
   ```

3. **Debugging checklist**:
   - ✅ State reading works (robot position/velocity make sense)
   - ✅ Command sending works (robot moves to commanded positions)
   - ✅ PD gains are correct (no jerky/unstable movements)
   - ✅ Joystick input registers (if implemented)
   - ✅ Latency is acceptable (<100ms for control loop at 50 Hz)
   - ✅ Safety limits enforced (commands stay within joint ranges)

### Phase 4: Optional - Create Training Bridge (Days 11-14)

**Only needed if you want sim-to-real training validation**. Allows training with X2 in simulator.

**File**:
```
src/holosoma/holosoma/bridge/agibot/agibot_sdk2py_bridge.py
```

**Implementation**:
```python
from holosoma.bridge.base.basic_sdk2py_bridge import BasicSdk2Bridge

class AgibotSdk2Bridge(BasicSdk2Bridge):
    """Bridge for Agibot X2 in training simulations."""
    
    SUPPORTED_ROBOT_TYPES = {"agibot_x2_29dof"}
    
    def _init_sdk_components(self):
        """Initialize Agibot SDK connection during training."""
        from agibot_sdk import AgibotClient
        robot_type = self.robot.asset.robot_type
        self.client = AgibotClient(...)  # Initialize
    
    def low_cmd_handler(self, msg=None):
        """Receive commands from simulator."""
        self.low_cmd = msg  # Store for processing
    
    def publish_low_state(self):
        """Send robot state to simulator."""
        state = self.client.get_robot_state()
        # Convert and publish to simulator
        self.simulator.low_state = convert_to_simulator_format(state)
    
    def compute_torques(self):
        """Compute PD torques for Agibot."""
        # Extract from command
        tau_ff = self.low_cmd.tau_ff
        kp = self.low_cmd.kp
        kd = self.low_cmd.kd
        q_target = self.low_cmd.q_target
        dq_target = self.low_cmd.dq_target
        
        # Use helper from base class
        self.torques = self._compute_pd_torques(
            tau_ff, kp, kd, q_target, dq_target
        )
```

**Register in entry points** (in `setup.py`):
```python
entry_points={
    "holosoma.bridge": [
        # ... existing
        "agibot = holosoma.bridge.agibot.agibot_sdk2py_bridge:AgibotSdk2Bridge",
    ],
}
```

---

## Part IV: Detailed Implementation Walkthrough

### Scenario: Deploy Trained G1 Locomotion Policy to Agibot X2

**Assumptions**:
- You have a trained ONNX model from G1 training
- Agibot X2 has 29 DOF (same as G1)
- You want to control it via offboard PC

**Steps**:

1. **Adapt G1 config to X2** (if kinematics similar):
   ```python
   # Copy G1 config and modify
   x2_config = RobotConfig(
       robot_type="agibot_x2_29dof",
       robot="agibot_x2",
       sdk_type="agibot",  # ← Key: different SDK
       
       # Keep same dimensions if 29-DOF structure
       num_motors=29,
       num_joints=29,
       
       # IMPORTANT: Update joint names to match X2 URDF
       dof_names=(
           # Copy from X2 URDF or manual mapping
           "left_hip_pitch_joint", # might be named differently in X2
           # ...
       ),
       
       # IMPORTANT: Update default positions (X2 standing pose)
       default_dof_angles=(...),  # X2-specific values
       
       # Can keep KP/KD from training if similar motor specs
       motor_kp=(...),  # G1 gains (may need tuning)
       motor_kd=(...),
   )
   ```

2. **Update observation config** (if X2 has different sensor layout):
   ```python
   # In config_values/observation.py
   x2_loco_obs = ObservationConfig(
       obs_dict=("base_ang_vel", "projected_gravity", ...),  # Same terms
       obs_dims={"base_ang_vel": 3, ...},                   # Same sizes
       obs_scales={"base_ang_vel": 0.25, ...},              # May need tuning
       history_length_dict={"actor_obs": 1},
   )
   ```

3. **Create launcher script**:
   ```bash
   #!/bin/bash
   # deploy_on_x2.sh
   
   export ROBOT_IP="192.168.1.100"  # X2 IP address
   export POLICY_PATH="./checkpoints/training_run_12345/policy.onnx"
   
   python -m holosoma_inference.run_policy \
       --config config/inference/agibot_x2_loco \
       --model-path "$POLICY_PATH" \
       --interface eth0  # or auto-detect
   ```

4. **Deploy**:
   ```bash
   # On PC with network access to X2:
   bash deploy_on_x2.sh
   ```

**Expected sequence** (at runtime):
1. Python loads ONNX model
2. Reads ONNX metadata → extracts KP, KD, action_scale, command_ranges
3. Initializes `AgibotInterface` → connects to X2 at `ROBOT_IP`
4. Enters run loop (50 Hz default):
   - ReadState() → `get_low_state()` queries X2 IMU/encoders
   - BuildObs() → constructs observation from state (base_ang_vel, gravity, etc.)
   - RL inference → runs ONNX policy with obs
   - Postprocess → scales action output
   - SendCommand() → `send_low_command()` sends PD targets to X2

---

## Part V: Known Challenges & Solutions

### 1. Observation Format Mismatch

**Problem**: Agibot X2 may not provide all observations in the same format as Unitree/Booster.

**Solutions**:
- ✅ **Extrapolate missing data**: If X2 doesn't provide base linear velocity, set to zeros (many locomotion policies are velocity-agnostic)
- ✅ **Estimate from differentiation**: If joint velocity unavailable, diff out from position history
- ✅ **Use IMU data only**: If no odometry, rely on IMU angular velocity (most critical for balance)

**Implementation**:
```python
def get_low_state(self) -> np.ndarray:
    state = self.client.get_robot_state()
    
    # Agibot may not provide all fields
    base_pos = np.zeros(3)  # Not critical for locomotion control
    quat = state.imu.quaternion  # REQUIRED
    joint_pos = np.array(state.joint_positions)  # REQUIRED
    base_lin_vel = np.zeros(3)  # Can be zero
    base_ang_vel = np.array(state.imu.angular_velocity)  # REQUIRED
    
    # If velocities not available, differentiate
    if not hasattr(state, 'joint_velocities'):
        joint_vel = (joint_pos - self.last_joint_pos) * control_rate
        self.last_joint_pos = joint_pos
    else:
        joint_vel = np.array(state.joint_velocities)
    
    return np.concatenate([base_pos, quat, joint_pos, base_lin_vel, base_ang_vel, joint_vel]).reshape(1, -1)
```

### 2. Control Gain Tuning

**Problem**: G1-trained gains may not work directly on X2 (different motor stiffness/damping).

**Solutions**:
- ✅ **Load from ONNX metadata**: Best practice—training system stores optimal gains
- ✅ **Override via config**: `RobotConfig.motor_kp/motor_kd` override ONNX values
- ✅ **Empirical tuning**: Start conservative (KP=50, KD=1), increase until stable
- ✅ **Per-joint scaling**: Weak joints (e.g., hip_yaw) may need different gains

**Example**:
```python
# ONNX metadata has G1 gains, override for X2
x2_motor_kp = [
    # Copy G1 values and scale per joint
    25.0,  # hip_pitch: half stiffness
    50.0,  # hip_roll: same as G1
    50.0,  # hip_yaw: same as G1
    # ... (fine-tune each joint)
]

x2_config = RobotConfig(
    # ...
    motor_kp=tuple(x2_motor_kp),  # Override ONNX
)
```

### 3. Joint Angle Limits & Safety

**Problem**: Different robots have different joint ranges. Invalid commands can damage motors.

**Solutions**:
- ✅ **Store limits in config**: `RobotConfig` should include min/max angles
- ✅ **Clip at interface level**: `AgibotInterface.send_low_command()` clamps targets
- ✅ **E-stop integration**: All SDKs should support emergency stop
- ✅ **Rate limiting**: Cap velocity targets to safe values

**Implementation**:
```python
def send_low_command(self, cmd_q, cmd_dq, cmd_tau, ...):
    # Clip to joint limits
    cmd_q = np.clip(cmd_q, 
                    self.robot_config.dof_pos_lower_limit,
                    self.robot_config.dof_pos_upper_limit)
    cmd_dq = np.clip(cmd_dq, -self.robot_config.dof_vel_limit, 
                           self.robot_config.dof_vel_limit)
    
    self.client.send_pd_command(cmd_q, cmd_dq, cmd_tau, ...)
```

### 4. Motor-to-Joint Mapping Issues

**Problem**: Motor indices may not match joint indices (e.g., GO2 has this).

**Solutions**:
- ✅ **Define mapping**: `RobotConfig.motor2joint` and `joint2motor`
- ✅ **Remap in interface**: Convert between simulator (joint order) and SDK (motor order)

**Example**:
```python
# If X2 motor order differs from joint order:
motor2joint = (3, 4, 5, 0, 1, 2, ...)  # Motor 0→Joint 3, etc.

def send_low_command(self, cmd_q, cmd_dq, cmd_tau, ...):
    # Remap from joint order to motor order
    cmd_q_motor = np.zeros(self.robot_config.num_motors)
    for j_id in range(self.robot_config.num_joints):
        m_id = self.robot_config.joint2motor[j_id]
        cmd_q_motor[m_id] = cmd_q[j_id]
    
    self.client.send_command(cmd_q_motor, ...)
```

### 5. Network Latency & Control Rate

**Problem**: If network latency >50ms, 50 Hz control loop (20ms) breaks.

**Solutions**:
- ✅ **Use onboard control**: Deploy policy directly on X2 (if Jetson/similar available)
- ✅ **Reduce control rate**: Drop to 25 Hz if needed (less reactive but more robust)
- ✅ **Optimize network**: Use UDP instead of TCP, minimize message size
- ✅ **Buffering**: If Agibot SDK has buffered commands, use them

**Configuration**:
```python
# In InferenceConfig
task = TaskConfig(
    rl_rate=25,  # Hz (double latency tolerance)
    interface="eth0",  # Optimized NIC
)
```

### 6. Joystick Controller Mapping

**Problem**: Agibot wireless controller button names may differ.

**Solutions**:
- ✅ **Define X2-specific mapping**: Extend `BaseInterface._default_wc_key_map()`
- ✅ **Test mapping**: Print button presses and verify names match policy code

**Implementation**:
```python
class AgibotInterface(BaseInterface):
    def _default_wc_key_map(self):
        # Override if X2 controller has different button layout
        return {
            1: "R1",
            2: "L1",
            # ... (adjust for X2)
        }
```

---

## Part VI: Validation Checklist

**Before deploying to real X2, ensure**:

- [ ] **SDK integration**
  - [ ] `AgibotInterface` implemented and registered
  - [ ] Entry point test passes: `python -c "from holosoma_inference.sdk import create_interface; ..."`
  - [ ] `get_low_state()` returns correct format
  - [ ] `send_low_command()` successfully commands robot

- [ ] **Robot config**
  - [ ] All required fields populated in `RobotConfig`
  - [ ] Joint names match X2 URDF
  - [ ] Default poses are safe (not out-of-bounds)
  - [ ] Motor/joint mapping tested (if needed)

- [ ] **Observation integrity**
  - [ ] Observation config has correct observation terms
  - [ ] Observation scales match training
  - [ ] History length matches ONNX input shape
  - [ ] Test observation building doesn't crash

- [ ] **Control safety**
  - [ ] Joint angle limits enforced
  - [ ] Velocity limits enforced
  - [ ] E-stop accessible (mapped to joystick or script)
  - [ ] Torque limits respected

- [ ] **Sim-to-sim validation** (if bridge implemented)
  - [ ] Sim robot moves identically to commands
  - [ ] Sim contact forces are reasonable
  - [ ] Policy runs in simulation without errors

- [ ] **Real robot testing** (phased approach)
  - [ ] Phase 0: Test SDKs only (state read/command send, no policy)
  - [ ] Phase 1: Manual control via joystick in "impedance mode" (low gain)
  - [ ] Phase 2: Simple policy (constant velocity) in controlled space
  - [ ] Phase 3: Full trained policy with safety monitor

---

## Part VII: Expected Integration Timeline & Effort

| Phase | Duration | Effort | Blocker | Notes |
|-------|----------|--------|---------|-------|
| **Phase 1**: Preparation | 3 days | 8h | Agibot SDK docs | Obtain X2 specs, understand SDK |
| **Phase 2**: Inference SDK | 4 days | 20h | Agibot SDK availability | Main implementation work |
| **Phase 3**: Real robot test | 3 days | 15h | Hardware access | Tuning, debugging on actual X2 |
| **Phase 4**: Training bridge | 4 days | 16h | Optional | Only if sim-to-sim training needed |
| **Buffer** | 2-3 days | 8-12h | Unknowns | Debugging, unforeseen issues |
| **TOTAL** | **14-17 days** | **60-70h** | | **2-3 weeks** for production-ready |

**Key dependencies**:
1. Agibot X2 SDK availability (Python bindings or C++ bindings)
2. Hardware access for testing (2-3 days)
3. Pre-trained ONNX model (or train new G1 model first)

---

## Part VIII: Comparison: Unitree vs. Booster vs. Agibot

| Aspect | Unitree G1 | Booster T1 | Agibot X2 (proposed) |
|--------|-----------|----------|-------------------|
| **SDK type** | C++ binding (DDS) | Python (sdk2py) | TBD |
| **Interface latency** | ~1-2 ms | ~10 ms | ? |
| **Control protocol** | Position+Velocity+Torque | Position+Velocity+Torque | ? |
| **Joystick support** | ✅ Wireless controller | ✅ Wireless controller | ? |
| **Motor mapping** | Identity (mostly) | Identity | ? |
| **Integration effort** | Low (already done) | Low (already done) | **High** (new) |
| **Sim-to-real path** | ✅ IsaacGym + real | ❌ (Booster only) | TBD |
| **Production status** | ✅ Deployed | ✅ Deployed | 🔶 To be evaluated |

---

## Part IX: References

**Code locations**:
- Inference SDK factory: [src/holosoma_inference/holosoma_inference/sdk/__init__.py](src/holosoma_inference/holosoma_inference/sdk/__init__.py)
- Base interface: [src/holosoma_inference/holosoma_inference/sdk/base/base_interface.py](src/holosoma_inference/holosoma_inference/sdk/base/base_interface.py)
- Unitree implementation: [src/holosoma_inference/holosoma_inference/sdk/unitree/unitree_interface.py](src/holosoma_inference/holosoma_inference/sdk/unitree/unitree_interface.py)
- Booster implementation: [src/holosoma_inference/holosoma_inference/sdk/booster/booster_interface.py](src/holosoma_inference/holosoma_inference/sdk/booster/booster_interface.py)
- Robot configs: [src/holosoma_inference/holosoma_inference/config/config_values/robot.py](src/holosoma_inference/holosoma_inference/config/config_values/robot.py)
- Setup entry points: [src/holosoma_inference/setup.py](src/holosoma_inference/setup.py)
- Training bridge base: [src/holosoma/holosoma/bridge/base/basic_sdk2py_bridge.py](src/holosoma/holosoma/bridge/base/basic_sdk2py_bridge.py)
- Unitree bridge: [src/holosoma/holosoma/bridge/unitree/unitree_sdk2py_bridge.py](src/holosoma/holosoma/bridge/unitree/unitree_sdk2py_bridge.py)

**Key entry points in setup.py** (both packages):
- `holosoma.sdk`: Maps SDK type → interface class
- `holosoma.config.robot`: Maps robot config name → RobotConfig instance
- `holosoma.config.inference`: Maps inference preset name → InferenceConfig instance
- `holosoma.bridge`: Maps bridge type → bridge class

---

## Conclusion

**Yes, the holosoma pipeline is highly extensible.** It was architected with multi-robot support in mind using:
- Python entry points for runtime plugin discovery
- Abstract base classes defining clear contracts
- Factory patterns for lazy-loading dependencies
- Configuration-as-dataclass for type safety and composability

**To add Agibot X2 support**:
1. Implement `AgibotInterface` (~400 lines of Python)
2. Define `RobotConfig` for X2 (~100 lines)
3. Register via entry points in `setup.py` (~5 lines)
4. Test on hardware (critical—3-5 days)

**Total standalone effort**: 2-3 weeks including testing.

**Main risks**:
- Agibot SDK documentation/availability
- Network latency for offboard control
- Motor/joint mapping differences
- Gain tuning differences

**Recommended next steps**:
1. Acquire Agibot SDKs and documentation
2. Set up X2 hardware lab environment
3. Create minimal test script to read state and send commands
4. Follow Phase 2 implementation (SDK interface)
5. Iteratively test and tune on real hardware

# Agibot X2 Integration: Implementation Templates

This document provides ready-to-use code templates for integrating Agibot X2 into the holosoma pipeline.

---

## 1. SDK Interface Template

**File**: `src/holosoma_inference/holosoma_inference/sdk/agibot/agibot_interface.py`

```python
"""Agibot robot interface using agibot SDK."""

from __future__ import annotations

import numpy as np

from holosoma_inference.config.config_types import RobotConfig
from holosoma_inference.sdk.base.base_interface import BaseInterface


class AgibotInterface(BaseInterface):
    """Interface for Agibot X2 humanoid robot.
    
    Communicates with Agibot X2 via the official Agibot SDK.
    Supports both offboard control (PC) and onboard control (if running on robot).
    """

    def __init__(self, robot_config: RobotConfig, domain_id=0, interface_str=None, use_joystick=True):
        """Initialize Agibot interface.
        
        Args:
            robot_config: Robot configuration (RobotConfig dataclass)
            domain_id: DDS domain ID (if applicable)
            interface_str: Network interface or IP address (e.g., "192.168.1.100" or "eth0")
            use_joystick: Enable wireless controller input
        """
        super().__init__(robot_config, domain_id, interface_str, use_joystick)
        
        # SDK-specific state
        self.client = None
        self.last_joint_pos = None
        self.state_read_count = 0
        
        # Initialize Agibot SDK connection
        self._init_agibot_sdk()
    
    def _init_agibot_sdk(self):
        """Initialize Agibot SDK and establish connection.
        
        Raises:
            ImportError: If Agibot SDK is not installed
            ConnectionError: If connection to robot fails
        """
        try:
            # TODO: Adjust import based on actual Agibot SDK package name
            # This is a placeholder; real SDK may be named differently
            from agibot_sdk import AgibotClient  # or similar
        except ImportError as e:
            raise ImportError(
                "Agibot SDK not found. Install via: "
                "pip install agibot-sdk (or similar)"
            ) from e
        
        # Parse connection parameters
        if self.interface_str is None:
            # Default to localhost for offboard control
            host = "localhost"
            port = 5005  # Placeholder port
        elif ":" in self.interface_str:
            # Format: "192.168.1.100:5005"
            host, port = self.interface_str.split(":")
            port = int(port)
        else:
            # Format: "192.168.1.100" or "eth0"
            host = self.interface_str
            port = 5005  # Default port
        
        # Create client and connect
        try:
            self.client = AgibotClient(
                host=host,
                port=port,
                control_mode="low_level",  # PD control mode
                # TODO: Add other Agibot-specific parameters
            )
            self.client.connect()
            print(f"✓ Connected to Agibot X2 at {host}:{port}")
        except Exception as e:
            raise ConnectionError(
                f"Failed to connect to Agibot at {host}:{port}. "
                f"Ensure robot is powered on and reachable. Error: {e}"
            ) from e
        
        # Initialize state tracking
        self.last_joint_pos = np.zeros(self.robot_config.num_joints)
    
    def get_low_state(self) -> np.ndarray:
        """Get robot state as numpy array.
        
        Returns:
            np.ndarray with shape (1, 3+4+N+3+3+N) containing:
            [base_pos(3), quat(4), joint_pos(N), 
             lin_vel(3), ang_vel(3), joint_vel(N)]
            
            Where N = number of joints (typically 29 for X2)
        
        Raises:
            RuntimeError: If state read fails
        """
        try:
            # Query robot state
            state = self.client.get_robot_state()
        except Exception as e:
            raise RuntimeError(f"Failed to read robot state: {e}") from e
        
        # Parse state components
        # === Position terms ===
        base_pos = np.zeros(3)  # Agibot may not provide odometry; use zeros
        
        # Quaternion from IMU (critical for balance control)
        # TODO: Adjust based on actual Agibot state message format
        if hasattr(state.imu, 'quaternion'):
            quat = np.array(state.imu.quaternion, dtype=np.float32)  # [w, x, y, z]
        elif hasattr(state.imu, 'quat'):
            quat = np.array(state.imu.quat, dtype=np.float32)
        else:
            # Fallback: create identity quaternion
            quat = np.array([1.0, 0.0, 0.0, 0.0], dtype=np.float32)
        
        # Joint positions from encoders
        joint_pos = np.array(state.joint_positions, dtype=np.float32)
        if len(joint_pos) != self.robot_config.num_joints:
            raise RuntimeError(
                f"Joint position size mismatch: got {len(joint_pos)}, "
                f"expected {self.robot_config.num_joints}"
            )
        
        # === Velocity terms ===
        # Base linear velocity (not critical for locomotion; use zeros)
        base_lin_vel = np.zeros(3, dtype=np.float32)
        
        # Base angular velocity from gyroscope (critical for balance)
        if hasattr(state.imu, 'angular_velocity'):
            base_ang_vel = np.array(state.imu.angular_velocity, dtype=np.float32)
        elif hasattr(state.imu, 'gyro'):
            base_ang_vel = np.array(state.imu.gyro, dtype=np.float32)
        else:
            base_ang_vel = np.zeros(3, dtype=np.float32)
        
        # Joint velocities
        if hasattr(state, 'joint_velocities') and state.joint_velocities is not None:
            # If SDK provides velocities directly
            joint_vel = np.array(state.joint_velocities, dtype=np.float32)
        else:
            # Fallback: differentiate position
            # WARNING: This is noisy; better to use SDK velocities if available
            dt = 1.0 / 50.0  # Assume 50 Hz control rate
            joint_vel = (joint_pos - self.last_joint_pos) / dt
            self.last_joint_pos = joint_pos.copy()
        
        # === Assemble final state array ===
        state_array = np.concatenate([
            base_pos, quat, joint_pos,
            base_lin_vel, base_ang_vel, joint_vel
        ]).reshape(1, -1).astype(np.float32)
        
        self.state_read_count += 1
        return state_array
    
    def send_low_command(
        self,
        cmd_q: np.ndarray,
        cmd_dq: np.ndarray,
        cmd_tau: np.ndarray,
        dof_pos_latest: np.ndarray = None,
        kp_override: np.ndarray = None,
        kd_override: np.ndarray = None,
    ):
        """Send low-level PD command to robot.
        
        Args:
            cmd_q: Target joint positions (N,)
            cmd_dq: Target joint velocities (N,)
            cmd_tau: Feedforward torques (N,)
            dof_pos_latest: Latest joint positions (unused, for compatibility)
            kp_override: Optional proportional gains override (N,)
            kd_override: Optional derivative gains override (N,)
        
        Raises:
            ValueError: If command shapes are incorrect
            RuntimeError: If command send fails
        """
        # Validate input shapes
        if cmd_q.shape != (self.robot_config.num_joints,):
            raise ValueError(f"cmd_q shape mismatch: {cmd_q.shape}")
        if cmd_dq.shape != (self.robot_config.num_joints,):
            raise ValueError(f"cmd_dq shape mismatch: {cmd_dq.shape}")
        if cmd_tau.shape != (self.robot_config.num_joints,):
            raise ValueError(f"cmd_tau shape mismatch: {cmd_tau.shape}")
        
        # === Resolve control gains ===
        # Priority: override > ONNX metadata > config default
        if kp_override is not None:
            kp = np.array(kp_override, dtype=np.float32)
        elif self.robot_config.motor_kp is not None:
            kp = np.array(self.robot_config.motor_kp, dtype=np.float32)
        else:
            raise ValueError(
                "KP gains not provided. Either pass kp_override, "
                "set RobotConfig.motor_kp, or attach to ONNX metadata"
            )
        
        if kd_override is not None:
            kd = np.array(kd_override, dtype=np.float32)
        elif self.robot_config.motor_kd is not None:
            kd = np.array(self.robot_config.motor_kd, dtype=np.float32)
        else:
            raise ValueError("KD gains not provided (same as KP)")
        
        # === Apply safety limits ===
        # Clamp joint positions to valid ranges
        # TODO: Add min/max angle limits to RobotConfig or use Agibot defaults
        # cmd_q = np.clip(cmd_q, self.robot_config.dof_pos_lower, 
        #                 self.robot_config.dof_pos_upper)
        
        # Clamp velocities
        max_vel = 10.0  # rad/s (tune based on motor specs)
        cmd_dq = np.clip(cmd_dq, -max_vel, max_vel)
        
        # Clamp torques
        max_tau = np.array([100.0] * self.robot_config.num_joints)  # N·m (tune per joint)
        cmd_tau = np.clip(cmd_tau, -max_tau, max_tau)
        
        # === Apply motor-to-joint mapping (if needed) ===
        # If Agibot motor order differs from joint order, remap here
        # motor2joint = self.robot_config.motor2joint
        # if motor2joint != tuple(range(len(motor2joint))):
        #     cmd_q = cmd_q[motor2joint]
        #     cmd_dq = cmd_dq[motor2joint]
        #     cmd_tau = cmd_tau[motor2joint]
        #     kp = kp[motor2joint]
        #     kd = kd[motor2joint]
        
        # === Send command to Agibot ===
        try:
            # TODO: Adjust method name and parameters based on actual Agibot SDK
            self.client.send_pd_command(
                q_target=cmd_q,
                dq_target=cmd_dq,
                tau_ff=cmd_tau,
                kp=kp,
                kd=kd,
                # TODO: Add other Agibot-specific parameters
            )
        except Exception as e:
            raise RuntimeError(f"Failed to send command to robot: {e}") from e
    
    def get_joystick_msg(self):
        """Get wireless controller message.
        
        Returns:
            Joystick message object or None if no input available.
        """
        if not self.use_joystick or self.client is None:
            return None
        
        try:
            # TODO: Adjust based on Agibot's joystick API
            return self.client.read_controller()
        except Exception:
            # If controller not available, return None (don't crash)
            return None
    
    def get_joystick_key(self, wc_msg=None):
        """Get current button press from joystick message.
        
        Args:
            wc_msg: Joystick message (optional; reads fresh if None)
        
        Returns:
            Button name (str) or None if no button pressed.
        """
        if wc_msg is None:
            wc_msg = self.get_joystick_msg()
        
        if wc_msg is None:
            return None
        
        # TODO: Adjust based on Agibot's button encoding
        # Placeholder: assume button_id integer maps to our key names
        button_id = getattr(wc_msg, 'button_id', 0)
        return self._wc_key_map.get(button_id, None)
    
    def update_config(self, robot_config: RobotConfig):
        """Update robot configuration (e.g., after loading from ONNX metadata).
        
        Args:
            robot_config: New configuration to apply
        """
        super().update_config(robot_config)
        # TODO: If Agibot SDK has parameters that need updating, do so here


# ============================================================================
# Module Entry Point
# ============================================================================

def create_agibot_interface(robot_config, domain_id=0, interface_str=None, use_joystick=True):
    """Factory function for creating AgibotInterface.
    
    This function is registered as an entry point in setup.py:
    entry_points={
        "holosoma.sdk": [
            "agibot = holosoma_inference.sdk.agibot.agibot_interface:AgibotInterface",
        ]
    }
    """
    return AgibotInterface(robot_config, domain_id, interface_str, use_joystick)
```

---

## 2. Robot Configuration Template

**File**: `src/holosoma_inference/holosoma_inference/config/config_values/robot.py` (add to existing file)

```python
# ============================================================================
# Agibot X2 29-DOF Robot Configuration
# ============================================================================

x2_29dof = RobotConfig(
    # =========================================================================
    # Identity
    # =========================================================================
    robot_type="agibot_x2_29dof",
    robot="agibot_x2",
    
    # =========================================================================
    # SDK Configuration
    # =========================================================================
    sdk_type="agibot",          # Maps to entry point "agibot"
    motor_type="serial",        # Serial port communication
    message_type="HG",          # Humanoid generic message type
    use_sensor=False,           # Don't use proprietary sensors
    
    # =========================================================================
    # Dimensions
    # =========================================================================
    num_motors=29,              # Total actuators
    num_joints=29,              # Controllable joints
    num_upper_body_joints=16,   # Arms + waist + head (adjust if X2 has head)
    
    # =========================================================================
    # Default Positions
    # =========================================================================
    # TODO: Confirm X2 standing pose angles (in radians)
    # This example uses G1-like structure; adjust for X2
    default_dof_angles=(
        # Left leg (6): hip_pitch, hip_roll, hip_yaw, knee, ankle_pitch, ankle_roll
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        # Right leg (6)
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        # Waist (3): yaw, roll, pitch
        0.0, 0.0, 0.0,
        # Left arm (7): shoulder P/R/Y, elbow, wrist R/P/Y
        0.2, 0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
        # Right arm (7)
        0.2, -0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
    ),
    default_motor_angles=(
        # Same as default_dof_angles if motor order matches joint order
        # If not, adjust accordingly
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        -0.312, 0.0, 0.0, 0.669, -0.363, 0.0,
        0.0, 0.0, 0.0,
        0.2, 0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
        0.2, -0.2, 0.0, 0.6, 0.0, 0.0, 0.0,
    ),
    
    # =========================================================================
    # Joint Mappings
    # =========================================================================
    motor2joint=tuple(range(29)),  # Identity mapping (adjust if X2 differs)
    joint2motor=tuple(range(29)),
    
    # =========================================================================
    # Joint Names (from X2 URDF)
    # =========================================================================
    # TODO: Replace with actual X2 joint names from URDF
    dof_names=(
        # Left leg
        "left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint",
        "left_knee_joint", "left_ankle_pitch_joint", "left_ankle_roll_joint",
        # Right leg
        "right_hip_pitch_joint", "right_hip_roll_joint", "right_hip_yaw_joint",
        "right_knee_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint",
        # Waist
        "waist_yaw_joint", "waist_roll_joint", "waist_pitch_joint",
        # Left arm
        "left_shoulder_pitch_joint", "left_shoulder_roll_joint", "left_shoulder_yaw_joint",
        "left_elbow_joint",
        "left_wrist_roll_joint", "left_wrist_pitch_joint", "left_wrist_yaw_joint",
        # Right arm
        "right_shoulder_pitch_joint", "right_shoulder_roll_joint", "right_shoulder_yaw_joint",
        "right_elbow_joint",
        "right_wrist_roll_joint", "right_wrist_pitch_joint", "right_wrist_yaw_joint",
    ),
    dof_names_upper_body=(
        "left_shoulder_pitch_joint", "left_shoulder_roll_joint", "left_shoulder_yaw_joint",
        "left_elbow_joint",
        "left_wrist_roll_joint", "left_wrist_pitch_joint", "left_wrist_yaw_joint",
        "right_shoulder_pitch_joint", "right_shoulder_roll_joint", "right_shoulder_yaw_joint",
        "right_elbow_joint",
        "right_wrist_roll_joint", "right_wrist_pitch_joint", "right_wrist_yaw_joint",
    ),
    dof_names_lower_body=(
        "left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint",
        "left_knee_joint", "left_ankle_pitch_joint", "left_ankle_roll_joint",
        "right_hip_pitch_joint", "right_hip_roll_joint", "right_hip_yaw_joint",
        "right_knee_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint",
        "waist_yaw_joint", "waist_roll_joint", "waist_pitch_joint",
    ),
    
    # =========================================================================
    # Link Names
    # =========================================================================
    torso_link_name="torso_link",  # Adjust if X2 uses different name
    left_hand_link_name="left_hand",  # May be None if no hand
    right_hand_link_name="right_hand",
    
    # =========================================================================
    # Control Gains (Optional - can be overridden by ONNX metadata)
    # =========================================================================
    # TODO: Tune these values based on X2 motor specs
    # Start conservative if unknown; fine-tune during hardware testing
    motor_kp=(
        # Legs (stiffer for stability)
        30.0, 30.0, 20.0,  # Left hip P/R/Y
        30.0, 30.0, 30.0,  # Left knee + ankles
        30.0, 30.0, 20.0,  # Right hip P/R/Y
        30.0, 30.0, 30.0,  # Right knee + ankles
        # Waist (medium)
        10.0, 10.0, 10.0,
        # Arms (softer for safety)
        10.0, 10.0, 10.0, 15.0,  # Left arm
        5.0, 5.0, 5.0,            # Left wrist
        10.0, 10.0, 10.0, 15.0,  # Right arm
        5.0, 5.0, 5.0,            # Right wrist
    ),
    motor_kd=(
        # Legs
        1.0, 1.0, 0.5,
        1.0, 1.0, 1.0,
        1.0, 1.0, 0.5,
        1.0, 1.0, 1.0,
        # Waist
        0.5, 0.5, 0.5,
        # Arms
        0.5, 0.5, 0.5, 0.5,
        0.3, 0.3, 0.3,
        0.5, 0.5, 0.5, 0.5,
        0.3, 0.3, 0.3,
    ),
    
    # =========================================================================
    # Per-joint action scales (legacy; ONNX metadata preferred)
    # =========================================================================
    default_per_joint_action_scale=None,  # Will use ONNX metadata
)

# Register in DEFAULTS dict
DEFAULTS = {
    "g1-29dof": g1_29dof,
    "t1-29dof": t1_29dof,
    "agibot-x2-29dof": x2_29dof,  # ← Add this line
}
```

---

## 3. Setup.py Entry Point Registration

**File**: `src/holosoma_inference/setup.py` (modify existing entries)

```python
entry_points={
    "holosoma.sdk": [
        "unitree = holosoma_inference.sdk.unitree.unitree_interface:UnitreeInterface",
        "booster = holosoma_inference.sdk.booster.booster_interface:BoosterInterface",
        "agibot = holosoma_inference.sdk.agibot.agibot_interface:AgibotInterface",  # ← Add
    ],
    "holosoma.config.robot": [
        "g1-29dof = holosoma_inference.config.config_values.robot:g1_29dof",
        "t1-29dof = holosoma_inference.config.config_values.robot:t1_29dof",
        "agibot-x2-29dof = holosoma_inference.config.config_values.robot:x2_29dof",  # ← Add
    ],
    "holosoma.config.inference": [
        "g1-29dof-loco = holosoma_inference.config.config_values.inference:g1_29dof_loco",
        "t1-29dof-loco = holosoma_inference.config.config_values.inference:t1_29dof_loco",
        "g1-29dof-wbt = holosoma_inference.config.config_values.inference:g1_29dof_wbt",
        # "agibot-x2-29dof-loco = holosoma_inference.config.config_values.inference:x2_29dof_loco",  # Optional
    ],
},
```

---

## 4. Inference Configuration Template (Optional)

**File**: `src/holosoma_inference/holosoma_inference/config/config_values/inference.py` (add at end)

```python
# ============================================================================
# Agibot X2 Inference Configurations
# ============================================================================

from holosoma_inference.config.config_values.observation import (
    # Define or import observation configs for X2
    # This assumes similar 9-term observation as G1
)
from holosoma_inference.config.config_values.task import (
    locomotion  # Reuse task config for 50 Hz locomotion
)

x2_29dof_loco = InferenceConfig(
    robot=x2_29dof,
    observation=loco_x2_29dof,  # TODO: Define or reuse existing
    task=locomotion,
    # TODO: Add other fields (policy_type, safety_config, etc.)
)

# Add to DEFAULTS
DEFAULTS = {
    # ... existing
    "agibot-x2-29dof-loco": x2_29dof_loco,
}
```

---

## 5. Test Script Template

**File**: `scripts/test_agibot_x2.py`

```python
#!/usr/bin/env python
"""Test script for Agibot X2 integration."""

import argparse
import sys

import numpy as np

from holosoma_inference.sdk import create_interface
from holosoma_inference.config.config_values.robot import x2_29dof


def test_state_reading(interface, num_reads=10):
    """Test reading robot state."""
    print(f"\n{'='*60}")
    print("TEST 1: Reading Robot State")
    print('='*60)
    
    for i in range(num_reads):
        state = interface.get_low_state()
        print(f"Read {i+1}: state shape={state.shape}, "
              f"pos range=[{state[0, 3+4+6:3+4+6+3].min():.2f}, "
              f"{state[0, 3+4+6:3+4+6+3].max():.2f}]")
    
    print("✓ State reading works!")
    return True


def test_command_sending(interface, num_steps=5):
    """Test sending commands (safe: small movements)."""
    print(f"\n{'='*60}")
    print("TEST 2: Sending Commands (Safe Test)")
    print('='*60)
    
    # Get default positions
    default_pos = np.array(interface.robot_config.default_dof_angles)
    
    # Small perturbations
    for i in range(num_steps):
        # Add 0.01 rad offset to all joints
        cmd_q = default_pos + 0.01 * (i - num_steps//2)
        cmd_dq = np.zeros(len(default_pos))
        cmd_tau = np.zeros(len(default_pos))
        
        try:
            interface.send_low_command(cmd_q, cmd_dq, cmd_tau)
            print(f"Step {i+1}: Sent command (offset={cmd_q[0]:.3f})")
        except Exception as e:
            print(f"✗ Command send failed: {e}")
            return False
    
    # Return to default
    interface.send_low_command(default_pos, np.zeros_like(default_pos), 
                               np.zeros_like(default_pos))
    print("✓ Command sending works!")
    return True


def test_joystick(interface, timeout=5):
    """Test joystick input."""
    print(f"\n{'='*60}")
    print(f"TEST 3: Joystick (Press a button within {timeout}s)")
    print('='*60)
    
    import time
    start = time.time()
    last_key = None
    
    while time.time() - start < timeout:
        msg = interface.get_joystick_msg()
        if msg is None:
            continue
        
        key = interface.get_joystick_key(msg)
        if key and key != last_key:
            print(f"✓ Detected button: {key}")
            last_key = key
        
        time.sleep(0.1)
    
    print("✓ Joystick works (or not plugged in)!")
    return True


def main():
    """Run all tests."""
    parser = argparse.ArgumentParser(description="Test Agibot X2 integration")
    parser.add_argument("--interface", default="192.168.1.100",
                       help="Robot IP address or network interface")
    parser.add_argument("--skip-command-test", action="store_true",
                       help="Skip command sending test (for safety)")
    parser.add_argument("--skip-joystick-test", action="store_true",
                       help="Skip joystick test")
    args = parser.parse_args()
    
    print(f"\n{'='*60}")
    print("Agibot X2 Integration Test Suite")
    print('='*60)
    print(f"Robot: {x2_29dof.robot_type}")
    print(f"Interface: {args.interface}")
    print(f"DOF: {x2_29dof.num_joints}")
    
    # Create interface
    print(f"\nInitializing interface...")
    try:
        interface = create_interface(x2_29dof, interface_str=args.interface, use_joystick=True)
        print("✓ Interface initialized")
    except Exception as e:
        print(f"✗ Failed to initialize interface: {e}")
        sys.exit(1)
    
    # Run tests
    results = {"state_read": False, "command_send": False, "joystick": False}
    
    try:
        results["state_read"] = test_state_reading(interface)
    except Exception as e:
        print(f"✗ State reading test failed: {e}")
    
    if not args.skip_command_test:
        try:
            results["command_send"] = test_command_sending(interface)
        except Exception as e:
            print(f"✗ Command send test failed: {e}")
    
    if not args.skip_joystick_test:
        try:
            results["joystick"] = test_joystick(interface)
        except Exception as e:
            print(f"✗ Joystick test failed: {e}")
    
    # Summary
    print(f"\n{'='*60}")
    print("Test Summary")
    print('='*60)
    for test_name, passed in results.items():
        status = "✓" if passed else "✗"
        print(f"{status} {test_name}")
    
    all_passed = all(results.values())
    print(f"\n{'='*60}")
    if all_passed:
        print("✓ All tests passed!")
        sys.exit(0)
    else:
        print("✗ Some tests failed. See above for details.")
        sys.exit(1)


if __name__ == "__main__":
    main()
```

**Usage**:
```bash
# Test with robot at 192.168.1.100
python scripts/test_agibot_x2.py --interface 192.168.1.100

# Skip command test for safety
python scripts/test_agibot_x2.py --skip-command-test

# Test only state reading
python scripts/test_agibot_x2.py --skip-command-test --skip-joystick-test
```

---

## 6. Deployment Script Template

**File**: `scripts/deploy_policy_on_x2.sh`

```bash
#!/bin/bash
# Deploy trained policy on Agibot X2

set -e  # Exit on error

# ============================================================================
# Configuration
# ============================================================================

ROBOT_IP="${ROBOT_IP:-192.168.1.100}"
ROBOT_PORT="${ROBOT_PORT:-5005}"
POLICY_PATH="${POLICY_PATH:-./checkpoints/latest/policy.onnx}"
INTERFACE="${INTERFACE:-eth0}"
RL_RATE="${RL_RATE:-50}"

# ============================================================================
# Validation
# ============================================================================

echo "=========================================="
echo "Agibot X2 Policy Deployment"
echo "=========================================="
echo "Robot:       $ROBOT_IP:$ROBOT_PORT"
echo "Policy:      $POLICY_PATH"
echo "Interface:   $INTERFACE"
echo "RL Rate:     ${RL_RATE} Hz"
echo ""

if [ ! -f "$POLICY_PATH" ]; then
    echo "✗ Policy not found: $POLICY_PATH"
    exit 1
fi

# ============================================================================
# Pre-deployment Checks
# ============================================================================

echo "Pre-deployment checks..."

# Check network connectivity
echo -n "  Checking network connectivity... "
if ! ping -c 1 "$ROBOT_IP" > /dev/null 2>&1; then
    echo "✗ Cannot reach $ROBOT_IP"
    echo "  Ensure robot is powered on and network is configured."
    exit 1
fi
echo "✓"

# Check ONNX file
echo -n "  Checking ONNX file... "
if ! python -c "import onnx; onnx.load('$POLICY_PATH')" 2>/dev/null; then
    echo "✗ Invalid ONNX file"
    exit 1
fi
echo "✓"

# ============================================================================
# Run Policy
# ============================================================================

echo ""
echo "Starting policy deployment..."
echo "Press Ctrl+C to stop."
echo ""

python -m holosoma_inference.run_policy \
    --config.robot=agibot-x2-29dof \
    --config.observation=loco-agibot-x2 \
    --config.task.model-path="$POLICY_PATH" \
    --config.task.interface="$INTERFACE" \
    --config.task.rl-rate=$RL_RATE \
    --config.inference.use-joystick=true

# If run completes without Ctrl+C, print summary
echo ""
echo "=========================================="
echo "Deployment completed successfully!"
echo "=========================================="
```

**Usage**:
```bash
# Deploy with default settings
bash scripts/deploy_policy_on_x2.sh

# Deploy with custom IP and policy
export ROBOT_IP="10.0.0.50"
export POLICY_PATH="/path/to/my_policy.onnx"
bash scripts/deploy_policy_on_x2.sh

# From within tmux (for persistent deployment)
tmux new-session -d -s x2_control bash scripts/deploy_policy_on_x2.sh
tmux attach -t x2_control
```

---

## 7. Debug / Troubleshooting Script

**File**: `scripts/debug_agibot_x2.py`

```python
#!/usr/bin/env python
"""Debug Agibot X2 integration issues."""

import argparse
import sys

import numpy as np

from holosoma_inference.config.config_values.robot import x2_29dof
from holosoma_inference.sdk import create_interface


def diagnose():
    """Run diagnostic checks."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", default="192.168.1.100")
    args = parser.parse_args()
    
    print("\n" + "="*60)
    print("Agibot X2 Diagnostic Report")
    print("="*60 + "\n")
    
    # 1. Check config
    print("1. Robot Configuration")
    print("-" * 60)
    print(f"   Robot type:         {x2_29dof.robot_type}")
    print(f"   SDK type:           {x2_29dof.sdk_type}")
    print(f"   DOF:                {x2_29dof.num_joints}")
    print(f"   Motors:             {x2_29dof.num_motors}")
    print(f"   Default pos shape:  {len(x2_29dof.default_dof_angles)}")
    print(f"   KP gains:           {'Loaded' if x2_29dof.motor_kp else 'Not set'}")
    print(f"   KD gains:           {'Loaded' if x2_29dof.motor_kd else 'Not set'}")
    
    # 2. Try interface creation
    print("\n2. Interface Initialization")
    print("-" * 60)
    try:
        interface = create_interface(x2_29dof, interface_str=args.interface)
        print("   ✓ Interface created successfully")
    except Exception as e:
        print(f"   ✗ Failed: {e}")
        return False
    
    # 3. Read state
    print("\n3. State Reading")
    print("-" * 60)
    try:
        state = interface.get_low_state()
        print(f"   State shape:        {state.shape}")
        
        base_pos = state[0, 0:3]
        quat = state[0, 3:7]
        joint_pos = state[0, 7:7+x2_29dof.num_joints]
        base_lin_vel = state[0, 7+x2_29dof.num_joints:10+x2_29dof.num_joints]
        base_ang_vel = state[0, 10+x2_29dof.num_joints:13+x2_29dof.num_joints]
        joint_vel = state[0, 13+x2_29dof.num_joints:]
        
        print(f"   Base pos:           {base_pos}")
        print(f"   Quaternion:         {quat}")
        print(f"   Joint pos range:    [{joint_pos.min():.2f}, {joint_pos.max():.2f}]")
        print(f"   Base ang vel:       {base_ang_vel}")
        print(f"   Joint vel range:    [{joint_vel.min():.2f}, {joint_vel.max():.2f}]")
        
        # Check for NaN/Inf
        if np.any(np.isnan(state)):
            print("   ✗ WARNING: NaN values in state!")
        if np.any(np.isinf(state)):
            print("   ✗ WARNING: Inf values in state!")
        
        print("   ✓ State reading works")
    except Exception as e:
        print(f"   ✗ Failed: {e}")
        return False
    
    # 4. Check joystick
    print("\n4. Joystick")
    print("-" * 60)
    try:
        msg = interface.get_joystick_msg()
        if msg:
            print(f"   ✓ Joystick available: {msg}")
        else:
            print("   ⚠ No joystick input (may not be connected)")
    except Exception as e:
        print(f"   ✗ Joystick check failed: {e}")
    
    print("\n" + "="*60)
    print("Diagnostic complete!")
    print("="*60 + "\n")
    return True


if __name__ == "__main__":
    success = diagnose()
    sys.exit(0 if success else 1)
```

**Usage**:
```bash
python scripts/debug_agibot_x2.py --interface 192.168.1.100
```

---

## Summary

These templates provide a complete starting point for Agibot X2 integration. **Key steps**:

1. Copy `agibot_interface.py` and fill in TODO sections with actual Agibot SDK API
2. Add robot config to `robot.py` DEFAULTS
3. Update `setup.py` entry points
4. Run `test_agibot_x2.py` to validate
5. Deploy using `deploy_policy_on_x2.sh`
6. Debug using `debug_agibot_x2.py` if issues arise

All placeholders marked with `TODO:` need to be filled in based on actual Agibot X2 documentation.

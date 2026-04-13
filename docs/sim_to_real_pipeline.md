# Holosoma Sim-to-Real Pipeline Analysis and Deployment Guide

Date: 2026-04-03

This document analyzes the sim-to-real pipeline in this repository and provides a practical deployment guide for trained policies, with special focus on locomotion policies.

## 1) End-to-end pipeline (training -> artifact -> deployment)

The project is split into two main runtime packages:

- `src/holosoma`: training, evaluation, simulator-side tools
- `src/holosoma_inference`: ONNX policy runtime for sim-to-sim and real robot execution

High-level flow:

1. Train a policy in `holosoma` (PPO or FastSAC) using IsaacGym/IsaacSim/MJWarp.
2. Save checkpoints (`.pt`) and export ONNX (`.onnx`) during training/eval.
3. Attach robot-critical metadata into ONNX (PD gains, command ranges, URDF, DOF names, action scale).
4. Run policy in `holosoma_inference/run_policy.py` on robot or in MuJoCo sim.
5. Inference loop reads low-level state, builds observations, runs ONNXRuntime, scales actions, and sends low-level commands through robot SDK interface.

## 2) Where sim-to-real is implemented

### 2.1 Training and ONNX export

- Training entrypoint: `src/holosoma/holosoma/train_agent.py`
- Evaluation/export entrypoint: `src/holosoma/holosoma/eval_agent.py`
- ONNX export helpers: `src/holosoma/holosoma/utils/inference_helpers.py`
- Algo implementations with export logic:
  - PPO: `src/holosoma/holosoma/agents/ppo/ppo.py`
  - FastSAC: `src/holosoma/holosoma/agents/fast_sac/fast_sac_agent.py`

Important behavior:

- `TrainingConfig.export_onnx` defaults to `True`.
- PPO and FastSAC both call `export(...)` during training checkpoints and at final save.
- Export code attaches ONNX metadata (`kp`, `kd`, `command_ranges`, `action_scale`, `robot_urdf`, `dof_names`).

Why this matters for real robots:

- The inference stack can load PD gains from ONNX metadata by default.
- This reduces mismatch risk between training-time and deployment-time controller gains.

### 2.2 Inference runtime and robot IO abstraction

- Runtime entrypoint: `src/holosoma_inference/holosoma_inference/run_policy.py`
- Core loop: `src/holosoma_inference/holosoma_inference/policies/base.py`
- Locomotion policy specifics: `src/holosoma_inference/holosoma_inference/policies/locomotion.py`
- Interface factory via entry points: `src/holosoma_inference/holosoma_inference/sdk/__init__.py`
- Unified SDK wrapper: `src/holosoma_inference/holosoma_inference/sdk/interface_wrapper.py`

The runtime is intentionally shared between sim-to-sim and sim-to-real:

- Same observation processing
- Same ONNX inference path
- Same command generation logic
- Different low-level backend depending on robot SDK and interface settings

### 2.3 Bridge layer for simulator-side closed loop

- Simulator runner: `src/holosoma/holosoma/run_sim.py`
- Bridge factory: `src/holosoma/holosoma/bridge/__init__.py`
- Base bridge class: `src/holosoma/holosoma/bridge/base/basic_sdk2py_bridge.py`

In sim-to-sim workflows, this bridge layer emulates/relays low-level robot SDK interactions in the simulator, helping keep the control path closer to hardware deployment.

## 3) Important functions and what they do

| Stage | Function / Method | File | Purpose |
|---|---|---|---|
| Train | `train(...)` | `src/holosoma/holosoma/train_agent.py` | Main training lifecycle and checkpoint flow |
| Export trigger (PPO) | `learn(...)` -> `self.export(...)` | `src/holosoma/holosoma/agents/ppo/ppo.py` | Exports ONNX at checkpoint/final steps |
| Export trigger (FastSAC) | `learn(...)` -> `self.export(...)` | `src/holosoma/holosoma/agents/fast_sac/fast_sac_agent.py` | Exports ONNX at checkpoint/final steps |
| ONNX export | `export_policy_as_onnx(...)` | `src/holosoma/holosoma/utils/inference_helpers.py` | Serializes actor to ONNX |
| Metadata attach | `attach_onnx_metadata(...)` | `src/holosoma/holosoma/utils/inference_helpers.py` | Writes PD gains, ranges, URDF, etc. into ONNX |
| Runtime init | `run_policy(...)` | `src/holosoma_inference/holosoma_inference/run_policy.py` | Builds policy class and starts control loop |
| Core policy loop | `BasePolicy.run(...)` | `src/holosoma_inference/holosoma_inference/policies/base.py` | Main periodic inference+command publish loop |
| Inference step | `BasePolicy.rl_inference(...)` | `src/holosoma_inference/holosoma_inference/policies/base.py` | Builds obs and executes ONNXRuntime session |
| Gains resolution | `BasePolicy._resolve_control_gains(...)` | `src/holosoma_inference/holosoma_inference/policies/base.py` | Chooses KP/KD from config override or ONNX metadata |
| Robot backend creation | `create_interface(...)` | `src/holosoma_inference/holosoma_inference/sdk/__init__.py` | Selects SDK implementation by `sdk_type` |
| State/cmd bridge | `InterfaceWrapper.get_low_state(...)` / `send_low_command(...)` | `src/holosoma_inference/holosoma_inference/sdk/interface_wrapper.py` | Unifies state read and command send across SDK backends |

## 4) Locomotion policy deployment to real robot

This section focuses on real robot locomotion deployment for G1/T1.

### 4.1 Prerequisites

- Hardware: Unitree G1 or Booster T1, Ethernet, controller/joystick
- Software setup: inference environment

```bash
bash scripts/setup_inference.sh
source scripts/source_inference_setup.sh
```

The setup installs `holosoma_inference` with robot SDK extras:

- Linux: `pip install -e src/holosoma_inference[unitree,booster]`
- macOS: Unitree only

### 4.2 Obtain/export the ONNX model

You can use any ONNX exported by training/eval.

Common options:

- Local file path: `/path/to/model.onnx`
- W and B URI: `wandb://entity/project/run/model.onnx`
- W and B HTTPS file URL

Example training command (FastSAC G1 locomotion):

```bash
source scripts/source_isaacgym_setup.sh
python src/holosoma/holosoma/train_agent.py \
    exp:g1-29dof-fast-sac \
    simulator:isaacgym \
    logger:wandb
```

### 4.3 Validate model/config compatibility before hardware run

Most common deployment mismatch points:

1. Observation history length must match training export.
2. Robot type and DOF layout must match the ONNX model.
3. Action scaling and PD gains must be consistent.

History-length override example:

```bash
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:g1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.interface eth0 \
    --observation.history_length_dict.actor_obs=4
```

### 4.4 Launch locomotion on real robot (offboard laptop)

G1 example:

```bash
source scripts/source_inference_setup.sh
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:g1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.use-joystick \
    --task.interface eth0
```

T1 example:

```bash
source scripts/source_inference_setup.sh
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:t1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.use-joystick \
    --task.interface eth0
```

If interface name is unknown, detect with `ifconfig` and pick the NIC on the robot subnet.

### 4.5 Runtime controls for locomotion

In the policy terminal:

- Start policy: `]` (or joystick A)
- Stop policy: `o` (or joystick B)
- Set default pose: `i` (or joystick Y)
- Toggle walk/stand: `=` (or joystick Start)
- Velocity commands:
  - Linear: `w a s d` (or joystick left stick)
  - Angular: `q e` (or joystick right stick)

### 4.6 Onboard and Docker deployment options

- Onboard Jetson: run the same `run_policy.py` command on robot computer (typically `--task.interface eth0`)
- Docker: use `src/holosoma_inference/docker/build.sh` and `run.sh`, then run policy inside container

These options preserve the same ONNX/runtime logic; only execution location changes.

## 5) Sim-to-sim as safety gate before hardware

Recommended validation order for locomotion:

1. Run MuJoCo bridge path first (`--task.interface lo`) with same ONNX.
2. Verify startup behavior, stand/walk transitions, and velocity control responsiveness.
3. Then move to real robot using the same model/config.

This catches observation/control issues before exposing hardware.

## 6) Practical deployment checklist (locomotion)

1. Confirm inference environment is active.
2. Confirm robot network interface and IP are correct.
3. Confirm ONNX path and robot config (`inference:g1-29dof-loco` or `inference:t1-29dof-loco`).
4. Confirm history length override if training used stacked observations.
5. Start in safe setup (gantry, damping/PREP procedure).
6. Start policy, then explicitly toggle walking mode.
7. Keep emergency stop command ready.

## 7) Key operational notes

- Inference defaults can include a secondary safety policy for G1 (`dual-mode` support). You can disable with `--secondary none`.
- Multiple model paths are supported (up to 9) and can be switched at runtime.
- If KP/KD are not passed by CLI config, runtime expects ONNX metadata to contain them.

## 8) Minimal command cookbook

### Sim-to-sim G1 locomotion (same machine)

```bash
# Terminal 1: simulator bridge
source scripts/source_mujoco_setup.sh
python src/holosoma/holosoma/run_sim.py robot:g1-29dof \
    --simulator.config.bridge.enabled=True

# Terminal 2: policy
source scripts/source_inference_setup.sh
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:g1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.interface lo
```

### Real robot G1 locomotion (offboard)

```bash
source scripts/source_inference_setup.sh
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:g1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.use-joystick \
    --task.interface eth0
```

### Real robot T1 locomotion (offboard)

```bash
source scripts/source_inference_setup.sh
python3 src/holosoma_inference/holosoma_inference/run_policy.py inference:t1-29dof-loco \
    --task.model-path /path/to/model.onnx \
    --task.use-joystick \
    --task.interface eth0
```

---

If you want, a next revision can include robot-specific preflight tables (G1 vs T1 network, mode switches, and emergency procedures) as a one-page runbook.

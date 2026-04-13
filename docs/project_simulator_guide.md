# Holosoma Project and Simulator Guide

This guide summarizes how the repository is organized, how simulator support is implemented, how G1 rewards are shaped for locomotion and whole-body tracking, what to do to add a new robot (Agibot X2), and what to expect when bringing up Isaac Gym on a modern RTX 5090D workstation.

## 1. Project structure

At the top level, the repository has three main Python packages under `src/`:

- `src/holosoma`: training framework (RL environments, simulator backends, managers, algorithms)
- `src/holosoma_inference`: inference and deployment (sim-to-sim and real robot runtime)
- `src/holosoma_retargeting`: retarget human motion data to robot trajectories

### 1.1 Core training package layout (`src/holosoma/holosoma`)

- `simulator/`
  - Physics backend abstraction and concrete simulators (`isaacgym`, `isaacsim`, `mujoco`)
- `envs/`
  - Task environments built with manager architecture
  - Main base class: `envs/base_task/base_task.py`
- `managers/`
  - Modular subsystems: action, observation, reward, termination, command, curriculum, randomization, terrain
- `agents/`
  - RL algorithms (PPO, FastSAC)
- `config_types/`
  - Typed config schemas
- `config_values/`
  - Concrete presets for robots, experiments, rewards, simulators, etc.
- Entrypoints
  - `train_agent.py`, `eval_agent.py`, `run_sim.py`, `replay.py`

### 1.2 Supporting packages

- `src/holosoma_inference/holosoma_inference`
  - `run_policy.py` and runtime policy execution stack
- `src/holosoma_retargeting/holosoma_retargeting`
  - robot/data format configs, retargeting optimization pipeline

### 1.3 Operational layer

- `scripts/`
  - environment setup and activation scripts for Isaac Gym, Isaac Sim, MuJoCo, inference, retargeting
- `docker/`
  - simulator-specific build images and reproducible runtime baselines
- `tests/ci/`
  - simulator-specific CI entry scripts

## 2. How this repo supports different simulators

The design is simulator-agnostic at the task level and simulator-specific at the backend level.

### 2.1 Backend abstraction

- Common interface: `simulator/base_simulator/base_simulator.py` (`BaseSimulator`)
- Concrete implementations:
  - `simulator/isaacgym/isaacgym.py`
  - `simulator/isaacsim/isaacsim.py`
  - `simulator/mujoco/mujoco.py`

This keeps environment logic reusable while allowing each backend to implement its own setup, asset loading, environment creation, and tensor synchronization.

### 2.2 Runtime backend selection

Simulator configs are declared in:

- `config_values/simulator.py`

Each preset uses `_target_` for late binding to a backend class:

- Isaac Gym -> `holosoma.simulator.isaacgym.isaacgym.IsaacGym`
- Isaac Sim -> `holosoma.simulator.isaacsim.isaacsim.IsaacSim`
- MuJoCo / MJWarp -> `holosoma.simulator.mujoco.mujoco.MuJoCo`

`BaseTask` resolves `_target_` dynamically (`get_class`) and instantiates the chosen simulator backend.

### 2.3 Task and manager architecture stays shared

- `envs/base_task/base_task.py` initializes all managers once the simulator is created:
  - observation, action, reward, termination, randomization, command, curriculum, terrain
- Because the managers work on unified environment state, the same task code can run on different simulator backends with configuration changes.

### 2.4 CI and setup separation by simulator

- Setup scripts:
  - `scripts/setup_isaacgym.sh`
  - `scripts/setup_isaacsim.sh`
  - `scripts/setup_mujoco.sh`
- CI script for Isaac Gym:
  - `tests/ci/isaacgym_ci_tests.sh` (uses markers to exclude Isaac Sim tests and optionally toggle multi-GPU tests)

## 3. Reward shaping for G1 locomotion and WBC

In this codebase, WBC is implemented as WBT (Whole-Body Tracking).

### 3.1 G1 locomotion reward shaping

Source: `config_values/loco/g1/reward.py`

#### `g1_29dof_loco` (PPO baseline)

| Term | Weight | Key params | Intuition |
| --- | ---: | --- | --- |
| `tracking_lin_vel` | 2.0 | `tracking_sigma=0.25` | Track commanded linear velocity |
| `tracking_ang_vel` | 1.5 | `tracking_sigma=0.25` | Track commanded yaw/angular velocity |
| `penalty_ang_vel_xy` | -1.0 | - | Penalize undesired roll/pitch angular velocity |
| `penalty_orientation` | -10.0 | - | Penalize base tilt |
| `penalty_action_rate` | -2.0 | - | Smooth action changes |
| `feet_phase` | 5.0 | `swing_height=0.09`, `tracking_sigma=0.008` | Encourage gait phase consistency |
| `pose` | -0.5 | per-DOF `pose_weights` | Regularize toward preferred posture |
| `penalty_close_feet_xy` | -10.0 | `close_feet_threshold=0.15` | Avoid feet crossing/collision |
| `penalty_feet_ori` | -5.0 | - | Keep foot orientation favorable |
| `alive` | 1.0 | - | Positive survival incentive |

#### `g1_29dof_loco_fast_sac`

Mostly same as PPO variant, with one notable difference:

- `alive` weight is `10.0` (instead of `1.0`)

### 3.2 G1 whole-body tracking (WBT/WBC) reward shaping

Source: `config_values/wbt/g1/reward.py`

#### `g1_29dof_wbt_reward` (base)

| Term | Weight | Key params | Intuition |
| --- | ---: | --- | --- |
| `motion_global_ref_position_error_exp` | 0.5 | `sigma=0.3` | Match global root position |
| `motion_global_ref_orientation_error_exp` | 0.5 | `sigma=0.4` | Match global root orientation |
| `motion_relative_body_position_error_exp` | 1.0 | `sigma=0.3` | Match relative body positions |
| `motion_relative_body_orientation_error_exp` | 1.0 | `sigma=0.4` | Match relative body orientations |
| `motion_global_body_lin_vel` | 1.0 | `sigma=1.0` | Match body linear velocities |
| `motion_global_body_ang_vel` | 1.0 | `sigma=3.14` | Match body angular velocities |
| `action_rate_l2` | -0.1 | - | Smooth policy outputs |
| `limits_dof_pos` | -10.0 | `soft_dof_pos_limit=0.9` | Penalize joint-limit violations |
| `undesired_contacts` | -0.1 | contact threshold/body-name regex | Penalize unwanted collisions |

#### `g1_29dof_wbt_fast_sac_reward`

Overrides selected terms relative to the base:

- `action_rate_l2` -> `-1.0`
- `motion_global_ref_position_error_exp` -> `1.0`
- `motion_relative_body_position_error_exp` -> `2.0`
- Other base terms remain active

#### `g1_29dof_wbt_reward_w_object`

Adds object-tracking terms on top of base WBT:

- `object_global_ref_position_error_exp` weight `1.0`, `sigma=0.3`
- `object_global_ref_orientation_error_exp` weight `1.0`, `sigma=0.4`

### 3.3 How reward terms are combined at runtime

Source: `managers/reward/manager.py`

For each timestep:

1. Compute each term value (`rew_raw`) from function/class implementation
2. Scale: `rew_scaled = rew_raw * term_weight * dt`
3. Sum all scaled terms into total reward buffer
4. Track episodic sums for logging

So the effective contribution is weight and simulation timestep dependent.

## 4. Pipeline to implement a new robot: Agibot X2

A practical path is to add X2 for training first, then inference, then retargeting.

### 4.1 Prepare robot assets

Collect and validate:

- URDF (required for Isaac Gym loading)
- USD (needed for Isaac Sim workflows if used)
- MuJoCo XML (needed for MuJoCo-based inference and retargeting workflows)

Place assets following current conventions under the robot data tree referenced by `RobotAssetConfig` in `config_values/robot.py`.

### 4.2 Add training robot config

File: `src/holosoma/holosoma/config_values/robot.py`

Create an X2 `RobotConfig` (copy from G1/T1 and adapt):

- DOF and body metadata (`dof_names`, `body_names`, counts)
- Contact/termination bodies (`terminate_after_contacts_on`, `penalize_contacts_on`)
- Joint limits, velocity/effort limits, armature, friction
- Control gains and action scales
- Asset paths (`urdf_file`, `usd_file`, `xml_file`) and robot type name
- Default pose/init state

Then register it in the module `DEFAULTS` mapping so Tyro subcommands can resolve it.

### 4.3 Add experiment presets

Files:

- `config_values/loco/<robot>/experiment.py`
- optionally `config_values/wbt/<robot>/experiment.py`
- and registry: `config_values/experiment.py`

Create X2 experiment presets by composing:

- environment class
- algorithm preset (PPO or FastSAC)
- X2 robot config
- reward/observation/action/termination/randomization/command/curriculum configs

Register under `DEFAULTS` in `config_values/experiment.py` so CLI can expose names like `exp:x2-...`.

### 4.4 Validate simulator wiring

`BaseTask` uses simulator `_target_` from config. Validate X2 on each target simulator you need:

- Isaac Gym smoke run first (`num_envs` small, headless)
- then scale up and tune gains/limits

Important checks:

- URDF joint order matches configured `dof_names`
- body names used in reward/termination exist in asset
- contact points and foot body names are correct

### 4.5 Inference integration

For deployment/sim-to-sim in `holosoma_inference`:

- ensure X2 model config is available
- ensure observation and action dimensions match exported policy
- ensure MuJoCo XML is valid if running MuJoCo inference path

### 4.6 Retargeting integration (if needed)

Primary guide:

- `src/holosoma_retargeting/holosoma_retargeting/ADD_ROBOT_TYPE_README.md`

Required edits there include:

- add robot defaults in `config_types/robot.py`
- add foot sticking links (required)
- add human-to-robot joint mappings in `config_types/data_type.py`
- provide robot URDF/XML in retargeting model directory conventions

## 5. Isaac Gym on RTX 5090D: CUDA and PyTorch compatibility

Short answer: likely possible, but high risk without manual compatibility work because this repo uses a legacy Isaac Gym stack.

### 5.1 What is pinned by this repo

From `scripts/setup_isaacgym.sh` and `docker/isaacgym.Dockerfile`:

- Isaac Gym Preview 4 download/install flow
- Conda env created with Python 3.8
- Docker baseline image: `nvcr.io/nvidia/isaac-sim:5.1.0`

From `src/holosoma/pyproject.toml`:

- `requires-python >=3.8`
- `numpy==1.23.5` pinned

This is an older dependency profile relative to current RTX 50-series software stacks.

### 5.2 Practical compatibility interpretation for 5090D

- GPU hardware capability itself is not the main blocker
- Main risk is software matrix mismatch among:
  - NVIDIA driver version
  - CUDA runtime/toolkit expected by Isaac Gym Preview 4
  - PyTorch build used inside that Isaac Gym environment
  - old Python/Numpy stack constraints

So this is a compatibility engineering problem, not a guaranteed yes/no from code alone.

### 5.3 Recommended bring-up strategy

1. Start from the provided Isaac Gym Docker path to reduce host mismatch.
2. Run a tiny smoke test (single-GPU, small env count) before long training.
3. Verify torch CUDA visibility inside the environment.
4. Run CI-like local tests using the same markers as `tests/ci/isaacgym_ci_tests.sh`.
5. Only then scale env count and enable multi-GPU.

### 5.4 If Isaac Gym is unstable on 5090D

Fallback options already supported by this repo:

- Isaac Sim path (`scripts/setup_isaacsim.sh`)
- MJWarp/MuJoCo path (`scripts/setup_mujoco.sh`) for locomotion training/eval workflows

Given the age of Isaac Gym Preview 4, planning for a fallback is recommended.

## Quick start checklist

- Read architecture files first:
  - `envs/base_task/base_task.py`
  - `simulator/base_simulator/base_simulator.py`
  - `config_values/simulator.py`
- For rewards, inspect and adjust:
  - `config_values/loco/g1/reward.py`
  - `config_values/wbt/g1/reward.py`
  - `managers/reward/manager.py`
- For Agibot X2 onboarding:
  - add X2 `RobotConfig` in `config_values/robot.py`
  - create/register X2 experiment presets in `config_values/experiment.py`
  - validate URDF DOF/body name alignment in simulator smoke tests
- For RTX 5090D + Isaac Gym:
  - start from Docker baseline
  - verify CUDA/PyTorch runtime before training
  - keep Isaac Sim or MJWarp as fallback path

from dataclasses import replace

from holosoma.config_types.experiment import ExperimentConfig, NightlyConfig, TrainingConfig
from holosoma.config_values import (
    action,
    algo,
    command,
    curriculum,
    observation,
    randomization,
    reward,
    robot,
    simulator,
    termination,
    terrain,
)

x2_29dof = ExperimentConfig(
    env_class="holosoma.envs.locomotion.locomotion_manager.LeggedRobotLocomotionManager",
    training=TrainingConfig(project="hv-x2-manager", name="x2_29dof_manager"),
    algo=replace(algo.ppo, config=replace(algo.ppo.config, num_learning_iterations=20000, use_symmetry=True)),
    simulator=simulator.isaacgym,
    robot=robot.x2_29dof,
    terrain=terrain.terrain_locomotion_mix,
    observation=observation.x2_29dof_loco_single_wolinvel,
    action=action.x2_29dof_joint_pos,
    termination=termination.x2_29dof_termination,
    randomization=randomization.x2_29dof_randomization,
    command=command.x2_29dof_command,
    curriculum=curriculum.x2_29dof_curriculum,
    reward=reward.x2_29dof_loco,
    nightly=NightlyConfig(
        iterations=5000,
        metrics={"Episode/rew_tracking_ang_vel": [0.3, "inf"], "Episode/rew_tracking_lin_vel": [0.5, "inf"]},
    ),
)


__all__ = ["x2_29dof"]

"""Locomotion reward presets for the X2 robot."""

from holosoma.config_types.reward import RewardManagerCfg, RewardTermCfg

x2_12dof_loco = RewardManagerCfg(
    only_positive_rewards=False,
    terms={
        "tracking_lin_vel": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:tracking_lin_vel",
            weight=1.5,
            params={"tracking_sigma": 0.25},
        ),
        "tracking_ang_vel": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:tracking_ang_vel",
            weight=0.5,
            params={"tracking_sigma": 0.25},
        ),
        "penalty_lin_vel_z": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_lin_vel_z",
            weight=-2.0,
            params={},
            tags=["penalty_curriculum"],
        ),
        "penalty_ang_vel_xy": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_ang_vel_xy",
            weight=-0.05,
            params={},
            tags=["penalty_curriculum"],
        ),
        "penalty_orientation": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_orientation",
            weight=-1.0,
            params={},
            tags=["penalty_curriculum"],
        ),
        "base_height": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:base_height",
            weight=-10.0,
            params={"desired_base_height": 0.65},
            tags=["penalty_curriculum"],
        ),
        "penalty_dof_acc": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_dof_acc",
            weight=-2.5e-7,
            params={},
            tags=["penalty_curriculum"],
        ),
        "penalty_dof_vel": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_dof_vel",
            weight=-0.001,
            params={},
            tags=["penalty_curriculum"],
        ),
        "penalty_action_rate": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:penalty_action_rate",
            weight=-0.01,
            params={},
            tags=["penalty_curriculum"],
        ),
        "limits_dof_pos": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:limits_dof_pos",
            weight=-5.0,
            params={"soft_dof_pos_limit": 0.9},
            tags=["penalty_curriculum"],
        ),
        "contact": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:contact",
            weight=0.0,
            params={"stance_threshold": 0.55, "contact_force_threshold": 1.0},
        ),
        "contact_no_vel": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:contact_no_vel",
            weight=-0.2,
            params={"contact_force_threshold": 1.0},
            tags=["penalty_curriculum"],
        ),
        "feet_swing_height": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:feet_swing_height",
            weight=-15.0,
            params={"target_height": 0.08, "contact_force_threshold": 1.0},
            tags=["penalty_curriculum"],
        ),
        "hip_pos": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:hip_pos",
            weight=-1.2,
            params={"hip_indices": [1, 2, 7, 8]},
            tags=["penalty_curriculum"],
        ),
        "alive": RewardTermCfg(
            func="holosoma.managers.reward.terms.locomotion:alive",
            weight=0.15,
            params={},
        ),
    },
)

__all__ = ["x2_12dof_loco"]

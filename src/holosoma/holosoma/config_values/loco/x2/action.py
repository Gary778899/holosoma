"""Locomotion action presets for the X2 robot."""

from holosoma.config_types.action import ActionManagerCfg, ActionTermCfg

x2_12dof_joint_pos = ActionManagerCfg(
    terms={
        "joint_control": ActionTermCfg(
            func="holosoma.managers.action.terms.joint_control:JointPositionActionTerm",
            params={},
            scale=1.0,
            clip=None,
        ),
    }
)

__all__ = ["x2_12dof_joint_pos"]

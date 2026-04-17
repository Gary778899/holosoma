"""Default curriculum manager configurations."""

from holosoma.config_values.loco.g1.curriculum import g1_29dof_curriculum, g1_29dof_curriculum_fast_sac
from holosoma.config_values.loco.t1.curriculum import t1_29dof_curriculum, t1_29dof_curriculum_fast_sac
from holosoma.config_values.loco.x2.curriculum import x2_29dof_curriculum
from holosoma.config_values.wbt.g1.curriculum import g1_29dof_wbt_curriculum

none = None

DEFAULTS = {
    "none": none,
    "t1_29dof": t1_29dof_curriculum,
    "g1_29dof": g1_29dof_curriculum,
    "t1_29dof_fast_sac": t1_29dof_curriculum_fast_sac,
    "g1_29dof_fast_sac": g1_29dof_curriculum_fast_sac,
    "x2_29dof": x2_29dof_curriculum,
    "g1_29dof_wbt_curriculum": g1_29dof_wbt_curriculum,
}

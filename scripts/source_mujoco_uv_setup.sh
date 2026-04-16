#!/usr/bin/env bash
# Detect script directory (works in both bash and zsh)
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
elif [ -n "${ZSH_VERSION}" ]; then
    SCRIPT_DIR=$( cd -- "$( dirname -- "${(%):-%x}" )" &> /dev/null && pwd )
fi

WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/.holosoma_deps}
UV_ENV_NAME=${UV_ENV_NAME:-hsmujoco}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}

if [ ! -f "$UV_ENV_DIR/bin/activate" ]; then
    echo "Error: uv environment not found at $UV_ENV_DIR"
    echo "Run: bash scripts/setup_mujoco_uv.sh"
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$UV_ENV_DIR/bin/activate"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$UV_ENV_DIR/lib"

if python -c "import mujoco" 2>/dev/null; then
    echo "MuJoCo uv environment activated successfully"
    echo "MuJoCo version: $(python -c 'import mujoco; print(mujoco.__version__)')"

    if python -c "import torch" 2>/dev/null; then
        echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)')"
    fi

    if python -c "import mujoco_warp" 2>/dev/null; then
        MUJOCO_WARP_COMMIT=$(git -C "$WORKSPACE_DIR/mujoco_warp" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "MuJoCo Warp commit: $MUJOCO_WARP_COMMIT"
    fi
else
    echo "Warning: MuJoCo environment activation may have issues"
fi

echo "Activated uv env: $UV_ENV_DIR"

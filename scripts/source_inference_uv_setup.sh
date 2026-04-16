# Detect script directory (works in both bash and zsh)
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
elif [ -n "${ZSH_VERSION}" ]; then
    SCRIPT_DIR=$( cd -- "$( dirname -- "${(%):-%x}" )" &> /dev/null && pwd )
fi

WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/.holosoma_deps}
UV_ENV_NAME=${UV_ENV_NAME:-hsinference}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}

if [ ! -f "$UV_ENV_DIR/bin/activate" ]; then
    echo "Error: uv environment not found at $UV_ENV_DIR"
    echo "Run: bash scripts/setup_inference_uv.sh"
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$UV_ENV_DIR/bin/activate"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$UV_ENV_DIR/lib"

# Keep compatibility with previous conda-based runtime path if present.
PY310_SITE_LIB="$UV_ENV_DIR/lib/python3.10/site-packages/lib"
if [ -d "$PY310_SITE_LIB" ]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$PY310_SITE_LIB"
fi

# Check UFW status if ufw command exists.
if command -v ufw >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
        UFW_STATUS_CMD="sudo ufw status"
    else
        UFW_STATUS_CMD="ufw status"
    fi

    if eval "$UFW_STATUS_CMD" | grep -q "Status: inactive"; then
        echo "UFW disabled"
    else
        echo "Warning: UFW is currently enabled."
    fi
fi

echo "Activated uv env: $UV_ENV_DIR"

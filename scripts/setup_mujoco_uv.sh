#!/usr/bin/env bash
# Exit on error, undefined vars, and failed pipes. Print commands.
set -euxo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR=$(dirname "$SCRIPT_DIR")

if ! command -v sudo &> /dev/null; then
  # In some container builds sudo is unavailable. Keep behavior compatible.
  echo "Warning: sudo could not be found; continuing without sudo wrapper"
  function sudo { "$@"; }
  export -f sudo
fi

# MuJoCo Warp version to install -- repo has no stable release tags.
MUJOCO_WARP_COMMIT=${MUJOCO_WARP_COMMIT:-09ec1da}

# Parse command-line arguments.
INSTALL_WARP=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-warp)
      INSTALL_WARP=false
      echo "MuJoCo Warp (GPU) installation disabled - CPU-only mode"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--no-warp]"
      echo ""
      echo "Options:"
      echo "  --no-warp      Skip MuJoCo Warp installation (CPU-only)"
      echo "  --help, -h     Show this help message"
      echo ""
      echo "Default: GPU-accelerated installation (WarpBackend + ClassicBackend)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--no-warp]"
      exit 1
      ;;
  esac
done

WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/.holosoma_deps}
UV_ENV_NAME=${UV_ENV_NAME:-hsmujoco}
UV_PYTHON=${UV_PYTHON:-3.10}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}

SENTINEL_FILE=${SENTINEL_FILE:-$WORKSPACE_DIR/.env_setup_finished_uv_$UV_ENV_NAME}
WARP_SENTINEL_FILE=${WARP_SENTINEL_FILE:-$WORKSPACE_DIR/.env_setup_finished_uv_${UV_ENV_NAME}_warp}
FORCE_REINSTALL=${FORCE_REINSTALL:-0}

echo "uv env name: $UV_ENV_NAME"
echo "uv env dir: $UV_ENV_DIR"
echo "uv python: $UV_PYTHON"
echo "sentinel file: $SENTINEL_FILE"
echo "warp sentinel file: $WARP_SENTINEL_FILE"

mkdir -p "$WORKSPACE_DIR" "$UV_ENV_ROOT"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: required command '$cmd' was not found in PATH"
    exit 1
  fi
}

install_system_packages() {
  local os_name
  os_name="$(uname -s)"

  if [[ "$os_name" == "Linux" ]]; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y \
        build-essential \
        cmake \
        git \
        curl \
        ffmpeg \
        libgl1-mesa-dev \
        libxinerama-dev \
        libxcursor-dev \
        libxrandr-dev \
        libxi-dev \
        libstdc++6
    else
      echo "Warning: apt-get not found; cannot auto-install Linux system packages"
    fi
  elif [[ "$os_name" == "Darwin" ]]; then
    if ! command -v brew &> /dev/null; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      echo >> "$HOME/.zprofile"
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    if ! command -v gcc &> /dev/null || ! command -v g++ &> /dev/null; then
      xcode-select --install || true
    fi

    brew install cmake git ffmpeg
  fi
}

version_ge() {
  # Returns success if $1 >= $2 using version sort.
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

require_cmd uv
install_system_packages
require_cmd git
require_cmd curl

if [[ "$FORCE_REINSTALL" == "1" ]]; then
  rm -f "$SENTINEL_FILE" "$WARP_SENTINEL_FILE"
fi

if [[ ! -f "$SENTINEL_FILE" ]]; then
  if [[ ! -d "$UV_ENV_DIR" ]]; then
    uv venv "$UV_ENV_DIR" --python "$UV_PYTHON"
  fi

  # shellcheck disable=SC1090
  source "$UV_ENV_DIR/bin/activate"

  uv pip install --upgrade pip setuptools wheel

  echo "Installing MuJoCo Python bindings..."
  uv pip install 'mujoco>=3.0.0'
  uv pip install mujoco-python-viewer

  echo "Installing Holosoma packages..."
  if [[ "$(uname -s)" == "Linux" ]]; then
    uv pip install -e "$ROOT_DIR/src/holosoma[unitree,booster]"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Warning: only unitree support for macOS"
    uv pip install -e "$ROOT_DIR/src/holosoma[unitree]"
  else
    echo "Unsupported OS: $(uname -s)"
    exit 1
  fi

  echo "Validating MuJoCo installation..."
  python -c "import mujoco; print(f'MuJoCo version: {mujoco.__version__}')"
  python -c "import mujoco_viewer; print('MuJoCo viewer imported successfully')"

  cat > "$WORKSPACE_DIR/validate_mujoco.py" << 'EOF'
#!/usr/bin/env python3
"""Validation script for MuJoCo installation."""

import sys
import mujoco


def validate_mujoco() -> bool:
    print(f"MuJoCo version: {mujoco.__version__}")

    xml_string = """
    <mujoco>
      <worldbody>
        <body name=\"box\" pos=\"0 0 1\">
          <geom type=\"box\" size=\"0.1 0.1 0.1\"/>
          <joint type=\"free\"/>
        </body>
      </worldbody>
    </mujoco>
    """

    try:
      model = mujoco.MjModel.from_xml_string(xml_string)
      data = mujoco.MjData(model)
      mujoco.mj_step(model, data)
      print("Basic MuJoCo functionality validated")
      print(f"Model has {model.nbody} bodies, {model.nq} DOFs")
      return True
    except Exception as exc:
      print(f"MuJoCo validation failed: {exc}")
      return False


if __name__ == "__main__":
    sys.exit(0 if validate_mujoco() else 1)
EOF

  python "$WORKSPACE_DIR/validate_mujoco.py"

  touch "$SENTINEL_FILE"
  echo ""
  echo "=========================================="
  echo "Base MuJoCo uv environment setup completed"
  echo "=========================================="
  echo "Activate with: source scripts/source_mujoco_uv_setup.sh"
fi

if [[ "$INSTALL_WARP" == "true" ]] && [[ ! -f "$WARP_SENTINEL_FILE" ]]; then
  echo "Installing MuJoCo Warp (GPU acceleration)..."

  # shellcheck disable=SC1090
  source "$UV_ENV_DIR/bin/activate"

  if ! command -v nvidia-smi &> /dev/null; then
    echo ""
    echo "ERROR: nvidia-smi not found"
    echo "MuJoCo Warp requires a CUDA-capable NVIDIA GPU"
    exit 1
  fi

  MIN_DRIVER_VERSION="550.54.14"
  DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"

  if [[ -z "$DRIVER_VERSION" ]] || ! version_ge "$DRIVER_VERSION" "$MIN_DRIVER_VERSION"; then
    echo ""
    echo "ERROR: NVIDIA driver not found or too old"
    if [[ -z "$DRIVER_VERSION" ]]; then
      echo "Current driver: not detected"
    else
      echo "Current driver: $DRIVER_VERSION"
    fi
    echo "Minimum required: $MIN_DRIVER_VERSION"
    exit 1
  fi

  echo "NVIDIA driver version is compatible: $DRIVER_VERSION"

  if [[ ! -d "$WORKSPACE_DIR/mujoco_warp" ]]; then
    git clone https://github.com/google-deepmind/mujoco_warp.git "$WORKSPACE_DIR/mujoco_warp"
    git -C "$WORKSPACE_DIR/mujoco_warp" checkout "$MUJOCO_WARP_COMMIT"
  fi

  uv pip install -e "$WORKSPACE_DIR/mujoco_warp[dev,cuda]"

  touch "$WARP_SENTINEL_FILE"

  echo ""
  echo "=========================================="
  echo "MuJoCo Warp installation completed"
  echo "=========================================="
  echo "Activate with: source scripts/source_mujoco_uv_setup.sh"
fi

echo ""
if [[ -f "$WARP_SENTINEL_FILE" ]]; then
  echo "MuJoCo environment ready with GPU acceleration (ClassicBackend + WarpBackend)"
elif [[ "$INSTALL_WARP" == "false" ]] && [[ -f "$SENTINEL_FILE" ]]; then
  echo "MuJoCo environment ready (CPU-only ClassicBackend)"
  echo "To add GPU acceleration later, run: bash scripts/setup_mujoco_uv.sh"
else
  echo "MuJoCo environment ready"
fi
echo "Use 'source scripts/source_mujoco_uv_setup.sh' to activate."

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

# Reuse the same workspace root convention as existing scripts.
WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/.holosoma_deps}

# uv + environment naming
UV_ENV_NAME=${UV_ENV_NAME:-hssim}
UV_PYTHON=${UV_PYTHON:-3.11}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}

# Sentinel controls
SENTINEL_FILE=${SENTINEL_FILE:-$WORKSPACE_DIR/.env_setup_finished_uv_$UV_ENV_NAME}
FORCE_REINSTALL=${FORCE_REINSTALL:-0}

# IsaacLab controls
ISAACLAB_DIR=${ISAACLAB_DIR:-$HOME/github/IsaacLab}
ISAACLAB_REF=${ISAACLAB_REF:-v2.3.0}
FORCE_ISAACLAB_REINSTALL=${FORCE_ISAACLAB_REINSTALL:-0}

# Isaac Sim controls
ISAACSIM_VERSION=${ISAACSIM_VERSION:-5.1.0}
SKIP_ISAACSIM_PIP_INSTALL=${SKIP_ISAACSIM_PIP_INSTALL:-0}
ISAACSIM_STANDALONE_DIR=${ISAACSIM_STANDALONE_DIR:-$HOME/isaacsim}

echo "uv env name: $UV_ENV_NAME"
echo "uv env dir: $UV_ENV_DIR"
echo "sentinel file: $SENTINEL_FILE"
echo "IsaacLab dir: $ISAACLAB_DIR"
echo "Isaac Sim standalone dir hint: $ISAACSIM_STANDALONE_DIR"

mkdir -p "$WORKSPACE_DIR" "$UV_ENV_ROOT"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: required command '$cmd' was not found in PATH"
    exit 1
  fi
}

require_cmd uv
require_cmd git
require_cmd sed
require_cmd realpath

warn_missing_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Warning: '$cmd' not found. $hint"
  fi
}

# Preflight checks only. This script intentionally does not install system packages.
warn_missing_cmd cmake "IsaacLab build steps may fail without it."
warn_missing_cmd gcc "Native extension builds may fail without a C compiler."
warn_missing_cmd g++ "Native extension builds may fail without a C++ compiler."

if [[ "$FORCE_REINSTALL" == "1" ]]; then
  rm -f "$SENTINEL_FILE"
fi

if [[ ! -f "$SENTINEL_FILE" ]]; then
  if [[ ! -d "$UV_ENV_DIR" ]]; then
    uv venv "$UV_ENV_DIR" --python "$UV_PYTHON"
  fi

  # shellcheck disable=SC1090
  source "$UV_ENV_DIR/bin/activate"

  # Keep toolchain current in the target venv.
  uv pip install --upgrade pip setuptools wheel

  # Install torch with the CUDA 12.8 index used by the conda-based flow.
  uv pip install -U torch==2.7.0 torchvision==0.22.0 --index-url https://download.pytorch.org/whl/cu128

  # Detect standalone Isaac Sim locations for user visibility.
  STANDALONE_ISAACSIM_PATH=""
  if [[ -d "$ISAACSIM_STANDALONE_DIR" ]]; then
    STANDALONE_ISAACSIM_PATH="$ISAACSIM_STANDALONE_DIR"
  elif compgen -G "$HOME/.local/share/ov/pkg/isaac-sim-*" > /dev/null; then
    STANDALONE_ISAACSIM_PATH="$(ls -d "$HOME"/.local/share/ov/pkg/isaac-sim-* | sort -V | tail -n 1)"
  fi

  ISAACSIM_IMPORTABLE=0
  if python -c "import isaacsim" &> /dev/null; then
    ISAACSIM_IMPORTABLE=1
  fi

  if [[ -n "$STANDALONE_ISAACSIM_PATH" ]]; then
    echo "Detected standalone Isaac Sim at: $STANDALONE_ISAACSIM_PATH"
  else
    echo "No standalone Isaac Sim install detected in common Omniverse locations"
  fi

  if [[ "$ISAACSIM_IMPORTABLE" == "1" ]]; then
    echo "isaacsim is already importable in uv env; skipping pip install"
  else
    if [[ "$SKIP_ISAACSIM_PIP_INSTALL" == "1" ]]; then
      echo "Warning: isaacsim is not importable and SKIP_ISAACSIM_PIP_INSTALL=1"
      echo "IsaacLab install may fail unless your standalone Isaac Sim is wired to this Python env"
    else
      # Install dependency from PyPI first, then isaacsim from NVIDIA index.
      uv pip install pyperclip
      uv pip install "isaacsim[all,extscache]==$ISAACSIM_VERSION" --extra-index-url https://pypi.nvidia.com
    fi
  fi

  ISAACLAB_IMPORTABLE=0
  if python -c "import isaaclab" &> /dev/null; then
    ISAACLAB_IMPORTABLE=1
  fi

  echo "Detection summary:"
  echo "  - standalone Isaac Sim path: ${STANDALONE_ISAACSIM_PATH:-not found}"
  echo "  - isaacsim importable in uv env: $ISAACSIM_IMPORTABLE"
  echo "  - isaaclab importable in uv env: $ISAACLAB_IMPORTABLE"

  # Reuse IsaacLab if it exists, otherwise clone at pinned ref.
  if [[ ! -d "$ISAACLAB_DIR/.git" ]]; then
    git clone https://github.com/isaac-sim/IsaacLab.git --branch "$ISAACLAB_REF" "$ISAACLAB_DIR"
  fi

  cd "$ISAACLAB_DIR"

  # setuptools>=81 removes pkg_resources; keep compatibility with current IsaacLab deps.
  uv pip install 'setuptools<81'
  echo 'setuptools<81' > build-constraints.txt
  export PIP_BUILD_CONSTRAINT="$(realpath build-constraints.txt)"

  # Fix upstream bug: flatdict should be 4.1.0.
  if grep -q 'flatdict==4.0.1' source/isaaclab/setup.py; then
    sed -i 's/flatdict==4.0.1/flatdict==4.1.0/' source/isaaclab/setup.py
  fi

  # Work-around for egl_probe cmake max version issue.
  export CMAKE_POLICY_VERSION_MINIMUM=3.5
  export OMNI_KIT_ACCEPT_EULA=${OMNI_KIT_ACCEPT_EULA:-1}

  if [[ "$FORCE_ISAACLAB_REINSTALL" == "1" ]]; then
    echo "FORCE_ISAACLAB_REINSTALL=1, running IsaacLab install"
    ./isaaclab.sh --install
  else
    if [[ "$ISAACLAB_IMPORTABLE" == "1" ]]; then
      echo "isaaclab is already importable in uv env; skipping ./isaaclab.sh --install"
    else
      ./isaaclab.sh --install
    fi
  fi

  # Install Holosoma package + robot SDK extras in editable mode.
  uv pip install -e "$ROOT_DIR/src/holosoma[unitree,booster]"

  # Force upgrade wandb to override rl-games constraint.
  uv pip install --upgrade 'wandb>=0.21.1'

  unset PIP_BUILD_CONSTRAINT

  touch "$SENTINEL_FILE"
else
  echo "Setup already complete. Reusing existing uv environment."
  echo "To force setup rerun: FORCE_REINSTALL=1 bash scripts/setup_isaacsim_uv.sh"
fi

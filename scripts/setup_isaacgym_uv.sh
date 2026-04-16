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
UV_ENV_NAME=${UV_ENV_NAME:-hsgym}
UV_PYTHON=${UV_PYTHON:-3.8}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}

# Sentinel controls
SENTINEL_FILE=${SENTINEL_FILE:-$WORKSPACE_DIR/.env_setup_finished_uv_$UV_ENV_NAME}
FORCE_REINSTALL=${FORCE_REINSTALL:-0}

# Isaac Gym controls
ISAACGYM_DIR=${ISAACGYM_DIR:-$WORKSPACE_DIR/isaacgym}
ISAACGYM_PACKAGE_URL=${ISAACGYM_PACKAGE_URL:-https://developer.nvidia.com/isaac-gym-preview-4}
ISAACGYM_PACKAGE_TAR=${ISAACGYM_PACKAGE_TAR:-$WORKSPACE_DIR/IsaacGym_Preview_4_Package.tar.gz}

echo "uv env name: $UV_ENV_NAME"
echo "uv env dir: $UV_ENV_DIR"
echo "uv python: $UV_PYTHON"
echo "sentinel file: $SENTINEL_FILE"
echo "Isaac Gym dir: $ISAACGYM_DIR"

mkdir -p "$WORKSPACE_DIR" "$UV_ENV_ROOT"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: required command '$cmd' was not found in PATH"
    exit 1
  fi
}

require_cmd uv

warn_missing_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Warning: '$cmd' not found. $hint"
  fi
}

# Install required system packages.
install_system_packages() {
  local os_name
  os_name="$(uname -s)"

  if [[ "$os_name" == "Linux" ]]; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y build-essential wget tar git coreutils
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

    brew install wget git coreutils
  fi
}

install_system_packages

# Validate expected tools after auto-install.
require_cmd wget
require_cmd tar
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

  # Install ffmpeg helper package for video encoding workflows.
  uv pip install -U imageio-ffmpeg

  # Install Isaac Gym package from NVIDIA tarball.
  if [[ ! -d "$ISAACGYM_DIR" ]]; then
    wget "$ISAACGYM_PACKAGE_URL" -O "$ISAACGYM_PACKAGE_TAR"
    tar -xzf "$ISAACGYM_PACKAGE_TAR" -C "$WORKSPACE_DIR"
  fi

  cd "$ISAACGYM_DIR/python"
  uv pip install -e .

  # Install Holosoma package + robot SDK extras in editable mode.
  uv pip install -e "$ROOT_DIR/src/holosoma[unitree,booster]"

  touch "$SENTINEL_FILE"
else
  echo "Setup already complete. Reusing existing uv environment."
  echo "To force setup rerun: FORCE_REINSTALL=1 bash scripts/setup_isaacgym_uv.sh"
fi
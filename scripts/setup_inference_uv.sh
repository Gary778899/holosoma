#!/usr/bin/env bash
# Exit on error, undefined vars, and failed pipes. Print commands.
set -euxo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR=$(dirname "$SCRIPT_DIR")

echo "Setting up inference uv environment"

if ! command -v sudo &> /dev/null; then
  # In some container builds sudo is unavailable. Keep behavior compatible.
  echo "Warning: sudo could not be found; continuing without sudo wrapper"
  function sudo { "$@"; }
  export -f sudo
fi

OS=$(uname -s)
ARCH=$(uname -m)

case "$ARCH" in
  "aarch64"|"arm64") ARCH="aarch64" ;;
  "x86_64") ARCH="x86_64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
  "Linux")
    INSTALL_CMD="sudo apt-get install -y"
    ;;
  "Darwin")
    INSTALL_CMD="brew install"
    ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/.holosoma_deps}
UV_ENV_NAME=${UV_ENV_NAME:-hsinference}
UV_PYTHON=${UV_PYTHON:-3.10}
UV_ENV_ROOT=${UV_ENV_ROOT:-$WORKSPACE_DIR/uv_envs}
UV_ENV_DIR=${UV_ENV_DIR:-$UV_ENV_ROOT/$UV_ENV_NAME}
SENTINEL_FILE=${SENTINEL_FILE:-$WORKSPACE_DIR/.env_setup_finished_uv_$UV_ENV_NAME}
FORCE_REINSTALL=${FORCE_REINSTALL:-0}

echo "uv env name: $UV_ENV_NAME"
echo "uv env dir: $UV_ENV_DIR"
echo "uv python: $UV_PYTHON"
echo "sentinel file: $SENTINEL_FILE"

mkdir -p "$WORKSPACE_DIR" "$UV_ENV_ROOT"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: required command '$cmd' was not found in PATH"
    exit 1
  fi
}

warn_missing_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" &> /dev/null; then
    echo "Warning: '$cmd' not found. $hint"
  fi
}

require_cmd uv
require_cmd git
warn_missing_cmd gcc "Native extension builds may fail without a C compiler."
warn_missing_cmd g++ "Native extension builds may fail without a C++ compiler."

if [[ "$FORCE_REINSTALL" == "1" ]]; then
  rm -f "$SENTINEL_FILE"
fi

if [[ ! -f "$SENTINEL_FILE" ]]; then
  # Install swig based on OS.
  if [[ "$OS" == "Darwin" ]]; then
    # Install brew if needed.
    if ! command -v brew &> /dev/null; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      echo >> "$HOME/.zprofile"
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi
  $INSTALL_CMD swig

  if [[ ! -d "$UV_ENV_DIR" ]]; then
    uv venv "$UV_ENV_DIR" --python "$UV_PYTHON"
  fi

  # shellcheck disable=SC1090
  source "$UV_ENV_DIR/bin/activate"

  # Keep toolchain current in the target venv.
  uv pip install --upgrade pip setuptools wheel

  # Ubuntu 24.04 GLIBCXX compatibility fallback. Conda-specific libstdcxx-ng
  # does not apply to uv; best effort install system libstdc++ runtime.
  if [[ "$OS" == "Linux" ]]; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update || true
      sudo apt-get install -y libstdc++6 || echo "Warning: could not install libstdc++6; continuing"
    else
      echo "Warning: apt-get not found, skipping libstdc++ fallback install"
    fi
  fi

  # Install holosoma_inference.
  # On macOS, only Unitree SDK is supported (Booster SDK is Linux-only).
  if [[ "$OS" == "Darwin" ]]; then
    echo "Note: Installing Unitree SDK only (Booster SDK is not supported on macOS)"
    uv pip install -e "$ROOT_DIR/src/holosoma_inference[unitree]"
  else
    uv pip install -e "$ROOT_DIR/src/holosoma_inference[unitree,booster]"
  fi

  # Setup a few things for ARM64 Linux (G1 Jetson).
  if [[ "$OS" == "Linux" && "$ARCH" == "aarch64" ]]; then
    sudo nvpmodel -m 0 2>/dev/null || true
    uv pip install "pin>=3.8.0"
  else
    if [[ ! -d "$WORKSPACE_DIR/unitree_sdk2_python" ]]; then
      git clone https://github.com/unitreerobotics/unitree_sdk2_python.git "$WORKSPACE_DIR/unitree_sdk2_python"
    fi
    uv pip install -e "$WORKSPACE_DIR/unitree_sdk2_python/"

    # Conda used pinocchio from conda-forge. In uv flow, try pin as fallback.
    if ! uv pip install "pin>=3.8.0"; then
      echo "Warning: could not install pin>=3.8.0 in uv env; continuing without it"
    fi
  fi

  cd "$ROOT_DIR"
  touch "$SENTINEL_FILE"
else
  echo "Setup already complete. Reusing existing uv environment."
  echo "To force setup rerun: FORCE_REINSTALL=1 bash scripts/setup_inference_uv.sh"
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR=$(dirname "$SCRIPT_DIR")

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path/to/model.onnx>"
  exit 2
fi

MODEL_PATH="$1"

if [[ -f "$ROOT_DIR/scripts/source_isaacgym_setup.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/scripts/source_isaacgym_setup.sh"
fi

python "$ROOT_DIR/scripts/validate_x2_onnx_metadata.py" "$MODEL_PATH"

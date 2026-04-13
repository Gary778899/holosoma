#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR=$(dirname "$SCRIPT_DIR")

if [[ -f "$ROOT_DIR/scripts/source_isaacgym_uv_setup.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/scripts/source_isaacgym_uv_setup.sh"
else
  echo "Error: missing uv activation script at $ROOT_DIR/scripts/source_isaacgym_uv_setup.sh"
  echo "Run: bash $ROOT_DIR/scripts/setup_isaacgym_uv.sh"
  exit 1
fi

NUM_ITERS=${NUM_ITERS:-2000}
NUM_ENVS=${NUM_ENVS:-512}
SEED=${SEED:-1}
DISABLE_VIDEO=${DISABLE_VIDEO:-1}
TERRAIN_CONFIG=${TERRAIN_CONFIG:-terrain-locomotion-plane}

export EXPORT_ONNX=${EXPORT_ONNX:-1}
export PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}

CMD=(
  python "$ROOT_DIR/src/holosoma/holosoma/train_agent.py"
  exp:x2-12dof
  simulator:isaacgym
  "terrain:${TERRAIN_CONFIG}"
  --training.seed="$SEED"
  --training.num_envs="$NUM_ENVS"
  --algo.config.num_learning_iterations="$NUM_ITERS"
)

if [[ "$DISABLE_VIDEO" == "1" ]]; then
  CMD+=(--logger.video.enabled=False)
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}"

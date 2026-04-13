#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
ROOT_DIR=$(dirname "$SCRIPT_DIR")

if [[ -f "$ROOT_DIR/scripts/source_isaacgym_setup.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/scripts/source_isaacgym_setup.sh"
fi

NUM_ITERS=${NUM_ITERS:-2000}
NUM_ENVS=${NUM_ENVS:-4096}
SEED=${SEED:-1}
DISABLE_VIDEO=${DISABLE_VIDEO:-1}

export EXPORT_ONNX=${EXPORT_ONNX:-1}

CMD=(
  python "$ROOT_DIR/src/holosoma/holosoma/train_agent.py"
  exp:x2-12dof
  simulator:isaacgym
  --training.seed="$SEED"
  --training.num-envs="$NUM_ENVS"
  --algo.config.num-learning-iterations="$NUM_ITERS"
)

if [[ "$DISABLE_VIDEO" == "1" ]]; then
  CMD+=(--logger.video.enabled=False)
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}"

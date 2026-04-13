#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

import onnx
import onnxruntime as ort

REQUIRED_KEYS = {
    "kp",
    "kd",
    "action_scale",
    "robot_type",
    "joint_names",
    "default_dof_pos",
    "observation_dim",
    "action_dim",
    "obs_scale_summary",
    "export_version",
}


def _load_metadata(model_path: Path) -> dict[str, object]:
    model = onnx.load(str(model_path))
    metadata: dict[str, object] = {}
    for prop in model.metadata_props:
        try:
            metadata[prop.key] = json.loads(prop.value)
        except Exception:
            metadata[prop.key] = prop.value
    return metadata


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_x2_onnx_metadata.py <model.onnx>")
        return 2

    model_path = Path(sys.argv[1]).expanduser().resolve()
    if not model_path.exists():
        print(f"ERROR: model does not exist: {model_path}")
        return 2

    session = ort.InferenceSession(str(model_path))
    inputs = session.get_inputs()
    outputs = session.get_outputs()

    if len(inputs) != 1 or inputs[0].name != "actor_obs":
        print(f"ERROR: unexpected ONNX input contract: {[i.name for i in inputs]}")
        return 1

    if len(outputs) == 0:
        print("ERROR: ONNX has no outputs")
        return 1

    metadata = _load_metadata(model_path)
    missing = sorted(REQUIRED_KEYS - set(metadata.keys()))
    if missing:
        print(f"ERROR: missing metadata keys: {missing}")
        return 1

    action_dim = int(metadata["action_dim"])
    observation_dim = int(metadata["observation_dim"])
    joint_names = list(metadata["joint_names"])
    kp = list(metadata["kp"])
    kd = list(metadata["kd"])
    default_dof_pos = list(metadata["default_dof_pos"])

    if action_dim != len(joint_names):
        print(f"ERROR: action_dim({action_dim}) != len(joint_names)({len(joint_names)})")
        return 1

    if len(kp) != action_dim or len(kd) != action_dim or len(default_dof_pos) != action_dim:
        print(
            "ERROR: metadata vector lengths mismatch: "
            f"kp={len(kp)}, kd={len(kd)}, default_dof_pos={len(default_dof_pos)}, action_dim={action_dim}"
        )
        return 1

    print("OK: ONNX contract and metadata validated")
    print(f"model: {model_path}")
    print(f"input: {inputs[0].name} shape={inputs[0].shape}")
    print(f"output[0]: {outputs[0].name} shape={outputs[0].shape}")
    print(f"observation_dim={observation_dim}, action_dim={action_dim}, robot_type={metadata['robot_type']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

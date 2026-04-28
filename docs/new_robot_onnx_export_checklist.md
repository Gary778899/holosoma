# 新机器人导入 holosoma 并导出 ONNX 清单

## 目标
- 让新机器人的训练配置、URDF 和动作/观测定义保持一致。
- 导出可直接用于 holosoma 推理的 ONNX。
- 尽量把运行时需要的参数写入 ONNX metadata，减少部署时手工维护。

## 建议原则
- 训练栈和推理栈尽量分离。
- URDF 和训练配置可以导入到 holosoma 作为“导出来源”，但不建议把完整训练工程都塞进 inference 仓库。
- 运行时真正需要的是：关节顺序、default angle、observation 定义、action 定义、kp/kd、模型输入输出契约。

## 需要准备的输入
- 新机器人的 URDF。
- 12 个关节的最终顺序表。
- 训练时 actor observation 的精确定义。
- 训练时 action space 的精确定义。
- 每个关节的默认角度。
- 每个关节的 kp/kd。
- 如果有历史帧或 recurrent state，也要明确说明。

## 导出前检查
1. 确认 URDF 中的关节命名与训练时完全一致。
2. 确认关节顺序和电机映射与实机 SDK 完全一致。
3. 确认 observation 的拼接顺序、单位、缩放系数与训练一致。
4. 确认 action 的维度、顺序、单位与训练一致。
5. 确认 default angle 使用训练时的值，而不是示例代码里的旧值。

## ONNX 导出时建议写入的 metadata
- `kp`
- `kd`
- `action_scale`
- `robot_type`
- `joint_names`
- `default_dof_pos`
- `observation_dim`
- `action_dim`
- `obs_scale_summary`
- `export_version`

## 导出步骤
1. 在训练代码里加载新机器人的 URDF 和训练配置。
2. 用训练时的输入样本跑一次前向，确认输入输出张量形状正确。
3. 导出 ONNX。
4. 把 kp/kd 和 action_scale 写入 ONNX metadata。
5. 用 onnxruntime 重新加载 ONNX，做一次等价性检查。
6. 在离线脚本里验证输出维度和数值范围是否合理。

## 需要特别注意的点
- 如果 policy 依赖 history buffer，导出时必须保证推理端历史长度完全一致。
- 如果是 locomotion，优先只导出 actor 所需部分，不要把不需要的训练图都带进来。
- 如果模型里有固定坐标系假设，要和 URDF 坐标系一致。
- 如果 kp/kd 不写入 metadata，推理端必须有可靠兜底配置。

## 推荐落地方式
- 把新机器人的训练定义放到独立仓库或独立目录。
- 在 holosoma 中只保留运行时必要的配置与导出结果。
- 最终部署只依赖：ONNX、metadata、robot config、SDK 适配层。

## 验收标准
- ONNX 能被 onnxruntime 正常加载。
- ONNX 输入维度和训练定义一致。
- ONNX metadata 能提供 kp/kd 或推理端有等价兜底。
- 推理输出维度和实机 12 关节映射完全一致。
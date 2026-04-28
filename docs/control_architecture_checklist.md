# 500Hz 控制流 + 50Hz 推理流 架构清单

## 目标
- 让 50Hz 的策略推理和 500Hz 的硬件控制稳定协作。
- 避免推理线程阻塞控制线程。
- 在超时或异常时自动切换到安全阻尼模式。

## 总体结构
- Thread 1：500Hz 控制回调，直接订阅 `/aima/hal/joint/leg/state`。
- Thread 2：50Hz 推理线程，读取共享观测，运行 ONNXRuntime，写入最新动作。
- Shared Buffer：共享 `Observation Buffer`、`Action Command`、`Heartbeat`。
- Watchdog：由 Thread 1 监控 Thread 2 的心跳是否超时。

## 推荐实现原则
- 使用单进程 monolithic ROS2 node。
- 使用无锁或低锁数据结构，例如 `std::atomic`、SPSC queue、双缓冲。
- 500Hz 回调里只做轻量工作：读状态、取最新动作、插值、限幅、发命令。
- ONNXRuntime 放在独立线程中，避免影响实时控制回调。

## 共享数据设计
- `Observation Buffer`：保存最新状态和推理输入。
- `Action Command`：保存最近一次推理输出的 12 维动作。
- `Action Timestamp`：记录动作更新时间。
- `Heartbeat`：记录推理线程最后一次正常完成推理的时间。

## 控制线程逻辑
1. 读取 `/aima/hal/joint/leg/state`。
2. 更新共享观测缓冲区。
3. 检查推理线程 heartbeat。
4. 如果超时，例如超过 50ms，进入安全阻尼模式。
5. 如果未超时，从共享区读取最新 action。
6. 对 action 做插值平滑。
7. 对 position / effort / kp / kd 做极限裁剪。
8. 发布 `/aima/hal/joint/leg/command`。

## 推理线程逻辑
1. 每 20ms 读取共享观测。
2. 执行 ONNXRuntime inference。
3. 写入最新 action 到共享区。
4. 更新 heartbeat。
5. 如果推理失败，保留上一帧 action 或触发降级标志。

## 安全阻尼模式
- 如果 heartbeat 超时，立即切换。
- 将所有关节 `stiffness (Kp)` 设为 0。
- 将 `damping (Kd)` 调高到安全值。
- 动作目标置零或保持当前位姿，取决于原厂安全策略。
- 优先使用原厂提供的阻尼模式切换接口；软件阻尼作为兜底。

## 是否可行的判断
- 结论：可行。
- 但前提是 500Hz 侧不能等待 50Hz 线程。
- 只要控制线程永远读“最新可用动作”，这套结构就合理。

## 适合用 C++ 的原因
- 500Hz 回调对抖动敏感。
- C++ 更适合做共享内存、原子变量、实时插值和 watchdog。
- Python 更适合做原型，不适合长期承担 500Hz 主闭环。

## 你需要确认的 SDK 约束
- `/aima/hal/joint/leg/command` 是否必须持续高频发布。
- 低频目标是否会被硬件保持，还是会超时失效。
- 掉线后是否自动进入阻尼。
- 原厂模式切换是否要求先注册输入源。

## 建议的开发顺序
1. 先验证低频目标是否可接受。
2. 再实现共享缓冲和 heartbeat。
3. 再加插值和平滑。
4. 最后加 watchdog 和安全阻尼。

## 验收标准
- 500Hz 控制回调稳定运行。
- 50Hz 推理延迟不会阻塞控制流。
- 推理超时后能在预期时间内进入安全阻尼。
- 动作输出无明显阶跃、无抖动、无错位。
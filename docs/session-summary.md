# 会话结论与当前基线

更新时间：2026-11-19

本文记录本会话确认的服务器与本地推理环境事实。需区分现场观测、用户给出的历史信息和待验证事项。

## 硬件与系统

- 主机：AMD Ryzen 9 3950X，64 GB 系统内存；Intel Arc Pro B60，24 GB 显存；另有旧 AMD 显卡。
- 用户提供的最近系统状态：Ubuntu 24.04.5，内核 `7.0.0-43-generic`，使用 Kobuk Intel Graphics PPA。
- 最近重启后，`xe` 驱动绑定 Intel B60，旧 AMD 显卡由 `radeon` 驱动绑定。
- 用户给出的启动日志显示 DMC `v2.6`、GuC `70.65.0`、HuC `8.2.10` 已加载。日志同时仍有 PCODE `Illegal Command` 和 “Thermal mailbox not supported” 提示。
- GuC 邮箱提示属于设备固件/平台能力告警，不能单凭告警消失证明推理稳定；当前也没有证据证明该告警或 `xe` 导致先前 CPU 硬件错误。
- Kobuk PPA 暂时保留。不要盲目添加旧 Intel 源、删除 PPA、安装整套平台包或升级 Ubuntu 大版本。

## 稳定性与取证

用户提供的历史事件：2026-10-28 15:45 出现 CPU5、Bank5 Machine Check 与 Data Fabric 错误复位，STATUS `bea0000000000108`、IPID `500b000000000`；16:13 出现 CPU3 Hard LOCKUP，并转储到 `/var/crash/202610281613/`（约 14 GB）。现场进程为 `valkey-server` 不能证明其为原因，也没有证据把故障归因于 `xe`。32 GB 在线内存检测一轮通过，但不足以完全排除内存不稳定。

服务器原有 kdump、rasdaemon 和 host-forensics 定时采样应继续保留；取证日志位于 `/var/log/host-forensics/`。变更驱动、内核或模型负载前后应检查这些设施与新日志，避免覆盖历史转储。

## 推理软件与模型

- 原生环境已验证过 PyTorch `2.14.0+xpu`，可见 `Intel(R) Arc(TM) Pro B60 Graphics`；一次 XPU 运算结果误差为 0。
- 后续环境报告显示 vLLM `0.33.0`、PyTorch `2.14.0+xpu`、XPU 可用。此前还存在 `intel/llm-scaler-vllm:0.26.0-b2` 镜像和停止的容器；不要自动启动它。
- 主模型选择：Qwen3.6-27B int4 AutoRound，服务器原有目录报告为 `/data/llm/models/Qwen3.6-27B-int4-AutoRound`。启动前必须再次确认该目录和量化配置存在。
- 已报告存在 Qwen3.6-35B-A3B-int4-mixed-AutoRound，但本阶段不把它选为主模型。
- 本地辅助模型下载已作为后台任务启动：Qwen3-Embedding-0.6B、Qwen3-Reranker-0.6B、Qwen3.5-4B；截至会话最后检查仍在下载，下载需完成后校验，不能将部分目录当作可运行模型。
- 2026-11-19 的只读复核确认服务器 vLLM 0.33.0 将设备识别为 `xpu` / `Intel(R) Arc(TM) Pro B60 Graphics`。量化注册器直接读取 checkpoint 的 `auto-round` 标记会报不支持；但 `/data/llm/tests/qwen36-27b-int4-20261117/REPORT.md` 和 `CONTEXT_LIMIT.md` 已验证通过显式 `--quantization inc` 与 `VLLM_XPU_INC_WNA16_BACKEND=w4a16` 走 oneDNN W4A16 加载 27B、35B。启动器需应用这组覆盖参数，不能只查原始元数据。旧 llm-scaler 容器仍停止，未启动。
- 既有 27B 测试：主力配置 `--dtype float16 --quantization inc --gpu-memory-utilization 0.93 --max-model-len 6144 --max-num-batched-tokens 2048 --max-num-seqs 8 --enforce-eager`；常规服务建议客户端并发 4。十轮并发 4 soak 平均聚合输出约 88.2 tok/s、预热后 TTFT 约 0.20 s，失败请求为 0；8 并发聚合速度约 83.7 tok/s，但平均 TTFT 0.91 s 且两条请求等到约 2.84 s。服务 cgroup 峰值 RAM 约 9.4 GB，GPU 显存权重约 17.46 GiB。
- 测试报告指出，较早一次 AutoRound/ARK 路径中断加载/关闭与 invalid-opcode trap、xe CCS reset 同时出现；因果关系未确认。显式 oneDNN W4A16 配置后重复加载和服务未观察到新的内核错误，因此 profile 固定该后端作为已测基线，不将其表述为硬件故障根因。
- 既有上下文测试：不做 CPU offload 的可重复上限约 25.6K；CPU offload 4 GiB、显存比例 0.96、`max-model-len=41600` 时处理约 41.4K token 请求成功，TTFT 76.5 s，cgroup RAM 峰值约 6.9 GiB。高上下文需单序列。测试曾发现 XPU Graph 长上下文捕获会令宿主可用 RAM 急剧下降；该上下文配置使用 `--enforce-eager`。41K 结果为单次合成精确检索，不代表普遍长文准确率。
- 既有 35B-A3B mixed-int4 测试：同样用 INC W4A16/eager；成功配置为显存比例 0.96、CPU offload 4 GiB、上下文 4096、batched tokens 1024、单序列。权重占约 18.6 GiB XPU、KV cache 约 0.85 GiB、RAM 峰值约 9.1 GB；没有证据说明其质量优于 27B。
- 较早用户笔记记录 Qwen3-8B FP16 平均约 27.31 tok/s、Qwen3-30B-A3B 通过 llm-scaler `sym_int4` 平均约 29.82 tok/s；它们与后续 oneDNN/INC 测试不是同一运行后端和模型任务，不直接据此排名。
- vLLM 0.33 CLI 支持 `--runner pooling`、`--convert embed`、`--hf-overrides`、`--chat-template` 和 `--language-model-only`。Embedding/Reranker/4B 的配置是保守初始值，尚未在 B60 加载验证；Qwen3.5 具体 XPU 与权重量化组合也需验证。
- 曾讨论原生 XPU + 上游 vLLM 与 OpenVINO 对照；不以已归档 IPEX 或 IPEX-LLM 作为新环境基础。较早的个人笔记也已复核，含 Qwen3-8B FP16 与 Qwen3-30B-A3B llm-scaler `sym_int4` 测试。

## 资源原则

64 GB RAM 不能简单当成模型可独占的 48 GB 预算。服务器最近一次 `free -h` 显示 Linux 可见约 60 GiB、`MemAvailable` 约 45 GiB。至少为其他进程与系统留出 16 GiB，并结合启动时 `MemAvailable`、权重加载峰值、运行时开销和并发/KV cache 实测设置限制。本仓库 systemd 示例使用 28 GiB `MemoryHigh`、32 GiB `MemoryMax`、swap 上限 0，并按模型要求启动前检查 `MemAvailable`；这是结合既有测试中 22–32 GiB cgroup 限额设置的安全起点，仍需观测实际峰值。

## 待办与验证边界

1. 下载完成后校验各辅助模型文件、提交版本和目录。
2. 辅助模型下载完成后核验权重；模型启动前验证路径、INC W4A16 参数、XPU 可见性和可用内存。
3. 先小并发/短上下文验证服务，再按一致条件测试质量、任务表现、首字延迟、吞吐、上下文、并发、显存/系统内存峰值和长期稳定性。
4. 启动模型或进行压力测试前，应明确目的、影响、验证和停止/回退步骤；本仓库创建服务文件不代表服务已安装、启用或启动。

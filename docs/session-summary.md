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
- 曾讨论原生 XPU + 上游 vLLM 与 OpenVINO 对照；不以已归档 IPEX 或 IPEX-LLM 作为新环境基础。历史测试文档路径曾由用户提供，但本地内容尚未在本仓库复核，模型优胜结论不在此臆造。

## 资源原则

64 GB RAM 不能简单当成模型可独占的 48 GB 预算。服务器最近一次 `free -h` 显示 Linux 可见约 60 GiB、`MemAvailable` 约 43 GiB。至少为其他进程与系统留出 16 GiB，并结合启动时 `MemAvailable`、权重加载峰值、运行时开销和并发/KV cache 实测设置限制。本仓库 systemd 示例使用 36 GiB `MemoryHigh`、40 GiB `MemoryMax`，并要求启动前至少 24 GiB `MemAvailable`，给非服务进程约 20 GiB cgroup 之外的物理内存余量；这只是安全起点，仍需观测实际峰值，压力测试另行制定并记录。

## 待办与验证边界

1. 下载完成后校验各辅助模型文件、提交版本和目录。
2. 只在用户决定启动时，验证主模型路径、AutoRound 量化元数据、XPU 可见性和可用内存。
3. 先小并发/短上下文验证服务，再按一致条件测试质量、任务表现、首字延迟、吞吐、上下文、并发、显存/系统内存峰值和长期稳定性。
4. 启动模型或进行压力测试前，应明确目的、影响、验证和停止/回退步骤；本仓库创建服务文件不代表服务已安装、启用或启动。

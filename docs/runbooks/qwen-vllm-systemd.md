# 部署 Qwen3.6-27B vLLM XPU 服务

本手册提供服务模板。创建本文件或推送仓库不会修改服务器。安装脚本需在 a3950x 的仓库副本中由管理员运行；它复制服务文件和启动脚本、创建默认环境文件（若不存在）并执行 `systemctl daemon-reload`，不会启用或启动模型。

## 适用基线

- Ubuntu 24.04.5、Intel B60 由 `xe` 驱动绑定。
- `/data/llm/envs/vllm-xpu-0.33.0` 中已有可运行的 vLLM `0.33.0` / PyTorch `2.14.0+xpu` 环境。
- 主模型目录 `/data/llm/models/Qwen3.6-27B-int4-AutoRound` 已完整且可读。
- 内存 64 GB（最近系统显示约 60 GiB 可见）。模板限制服务 cgroup 到 `MemoryHigh=36G` / `MemoryMax=40G`，保留约 20 GiB 给系统和其他进程。启动脚本还要求启动时至少 24 GiB `MemAvailable`。这只是保守起点，不替代按实际负载核算，也不保证模型一定能装载。
- 服务默认只监听 `127.0.0.1:8000`，离机访问应通过 SSH 隧道或经审查的认证反向代理，不要直接暴露未认证端口。

## 安装前检查

在服务器只读确认内存、磁盘、模型文件、环境版本和 GPU：

```bash
free -h
df -h /data/llm
test -d /data/llm/models/Qwen3.6-27B-int4-AutoRound
/data/llm/envs/vllm-xpu-0.33.0/bin/python -c 'import torch; print(torch.__version__, torch.xpu.is_available(), [torch.xpu.get_device_name(i) for i in range(torch.xpu.device_count())])'
```

确认模型目录完整、当前可用内存足够，并检查既有 kdump、rasdaemon、host-forensics 状态。服务启动会加载约 27B int4 模型，消耗 B60 显存和系统内存；首次启动可能失败或占用较长时间。此步骤不进行压力测试。

## 安装服务文件

将仓库放在服务器，例如 `/data/llm/run-llm`，并审阅 `config/serve-qwen.env.example`。安装会写入 `/etc/systemd/system/llm-vllm.service`、`/data/llm/scripts/serve-qwen.sh`，创建所需配置/日志/缓存目录，并在环境文件不存在时复制默认配置，然后重新加载 systemd。若同名 unit 或脚本已存在，安装器先保留带时间戳的副本。它不会启动服务。

```bash
cd /data/llm/run-llm
sudo ./scripts/install-systemd-service.sh
sudoedit /data/llm/config/serve-qwen.env
systemctl cat llm-vllm.service
```

默认参数为 8K 上下文、最多 2 个并行序列、GPU 显存使用率 0.90。应先按模型配置与实际可用显存决定上下文/并发；提高会增加显存或 RAM 峰值。启动脚本已用服务器上的 vLLM 0.33.0 核对参数；该构建自动识别 `xpu` 平台，因此不传入该版本不支持的 `--device` 选项。systemd 的 `MemoryHigh=36G` / `MemoryMax=40G` 是服务进程组限制；如更改，必须仍为其他程序留至少 16 GB，并考虑系统当前可用内存和加载开销。

## 手动启动与验证

由用户决定何时启动。启动前复查 `MemAvailable`；脚本会再次检查最低值、模型目录、vLLM 环境和 B60 XPU 可用性，并默认启用 Hugging Face 离线模式，避免启动时下载文件。服务失败后不会自动反复重启；查看日志、排除原因后再手动重启。

```bash
sudo systemctl start llm-vllm.service
systemctl status llm-vllm.service --no-pager
journalctl -u llm-vllm.service -n 100 --no-pager
tail -n 100 /data/llm/logs/qwen3.6-27b-vllm.log
curl --fail http://127.0.0.1:8000/v1/models
```

服务停止：

```bash
sudo systemctl stop llm-vllm.service
```

需要开机启动时，先完成稳定性验证再显式执行 `sudo systemctl enable llm-vllm.service`。该模板不默认启用开机自启。

## 回退

```bash
sudo systemctl disable --now llm-vllm.service
sudo rm /etc/systemd/system/llm-vllm.service
sudo systemctl daemon-reload
```

回退只移除服务定义并停止服务，不删除模型、虚拟环境、缓存、日志或历史取证数据。若安装器生成了 `.pre-a3950x-run-llm.<时间戳>` 备份，应先将相应备份恢复到原路径，然后执行 `systemctl daemon-reload`。环境文件由安装器保留，回退时无需删除。

## 故障记录

停止服务后保留 journal 和 `/data/llm/logs/qwen3.6-27b-vllm.log`。记录启动时可用内存、`systemctl show llm-vllm -p MemoryPeak`、GPU 显存/利用率、首字延迟和输出吞吐。遇到机器检查、硬锁死或内核错误时，优先保留 `/var/crash`、`/var/log/host-forensics/` 和系统 journal，不要把同时出现的模型进程直接当成故障根因。

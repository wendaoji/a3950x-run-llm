# 模型启动配置与调参

仓库使用一个通用入口 `scripts/serve-model.sh` 和 `config/models/*.env` 模型配置。模型服务由 systemd template unit `llm-vllm@.service` 管理。启动脚本默认离线加载本地文件；下载未完成、vLLM 版本不符、B60 XPU 不可见或可用内存不足时会拒绝启动。

## 配置一览

27B/35B 参数按服务器已有测试报告还原；辅助模型参数是保守初值，不是基准测试结果。本次没有启动模型。checkpoint 的 `auto-round` 标记不能让此环境直接选中量化实现；既有测试显式指定 `--quantization inc` 并设置 `VLLM_XPU_INC_WNA16_BACKEND=w4a16` 后，使用 oneDNN W4A16 在 B60 上成功加载。Embedding、Reranker 和未量化 Qwen3.5-4B 可走原生 vLLM，仍须等完整权重并首次验证。vLLM 0.33 官方文档给出 pooling runner、Qwen3-Reranker 转换方式及 Qwen3.5 的多模态支持；Intel XPU 支持矩阵不等价于每个具体模型组合已在这台 B60 上验证。

| profile | 用途 | 初始上下文 | 并发序列 | 显存规划比例 | 可用 RAM 启动门槛 | 备注 |
|---|---|---:|---:|---:|---:|---|
| `qwen36-27b` | 主力编程/文本生成 | 6K | vLLM 最多 8；常用客户端并发 4 | 0.93 | 32 GiB | 按已通过的 INC oneDNN W4A16 报告配置；FP16、eager。 |
| `qwen36-27b-long-context` | 单请求长文档处理 | 41.6K | 1 | 0.96 | 32 GiB | 已测 4 GiB CPU offload；约 41K 请求 TTFT 76.5 秒。 |
| `qwen36-35b-a3b` | 35B-A3B 对照 | 4K | 1 | 0.96 | 28 GiB | 已测 INC W4A16 + 4 GiB CPU offload；KV cache 余量很小。 |
| `qwen3-embedding-0.6b` | 向量召回/代码检索 | 8K | 8 | 0.35 | 20 GiB | pooling + embed；索引批处理可以提高序列数。 |
| `qwen3-reranker-0.6b` | 候选重排 | 8K | 4 | 0.35 | 20 GiB | pooling；使用 Qwen 专用分类转换和随模型下载的 chat template。 |
| `qwen35-4b` | 轻量文本/图片任务 | 8K | 1 | 0.75 | 24 GiB | 保留视觉能力；图像尺寸/数量会增加运行时内存。 |

GPU 显存规划比例是 vLLM 运行时的设备内存预算参数，不是系统 RAM 限额。所有模板服务共用 `/data/llm/locks/vllm-xpu.lock`，同一时刻只允许通过本启动器运行一个模型，避免互相争抢唯一的 B60。systemd 每个服务 RAM cgroup 上限为 32 GiB（软高水位 28 GiB，swap 上限 0）；约 60.7 GiB 的可见内存中，给 cgroup 外系统与其他程序留下约 28 GiB。既有 27B/35B 测试分别在 32 GiB 和更低的 22 GiB cgroup 限额下完成且保持 16 GiB RAM reserve。每次启动仍检查 profile 中的 `MIN_AVAILABLE_GIB`。

27B 常规报告的主要数值：并发 4 十轮 soak 平均聚合输出约 88.2 tok/s，预热后 TTFT 约 0.20 s，请求失败为 0；并发 8 聚合约 83.7 tok/s，但平均 TTFT 0.91 s 且有约 2.84 s 排队请求。GPU 权重占用约 17.46 GiB，服务 cgroup RAM 峰值约 9.4 GB。35B 的 4 GiB offload 运行仅剩约 0.85 GiB KV cache，不能据小样本宣称质量胜过 27B。详见 `/data/llm/tests/qwen36-27b-int4-20261117/REPORT.md` 和 `CONTEXT_LIMIT.md`。

质量 smoke test 中，27B 的 SQL 与中文摘要通过；但逻辑题答错、一次代码回答把列表切片与 O(1) 空间复杂度并列、一次错误声称修改 Python list 会使迭代器抛异常，并在一个约 4.6K token 的 planted-code 检索题漏答。35B 也答错逻辑题且有截断；其 Kadane 算法样例正确。这些样本规模很小，但说明编程 agent 必须保留单元测试、lint、类型检查和人工审查，不能把模型输出当成已验证代码。

较早的用户笔记记录：Qwen3-8B FP16 在 Intel llm-scaler 上约 27.31 tok/s；Qwen3-30B-A3B 通过 llm-scaler `sym_int4` 在线量化约 29.82 tok/s。该结果与当前 Qwen3.6 的 upstream vLLM + INC oneDNN W4A16 不同 runtime、模型和测试轮次，不能直接做严格性能排名。

## 先检查模型是否完整

最近只读盘点时，Embedding、Reranker、Qwen3.5-4B 的 Hugging Face 后台下载仍在运行，目录中仍有 `.incomplete` 权重分片。启动器检测到任何 `.incomplete` 文件或缺少分片时会退出。下载结束后检查：

```bash
systemctl --user status llm-aux-models-download.service --no-pager
find /data/llm/models/Qwen3-Embedding-0.6B /data/llm/models/Qwen3-Reranker-0.6B /data/llm/models/Qwen3.5-4B -type f -name '*.incomplete' -print
find /data/llm/models/Qwen3-Embedding-0.6B /data/llm/models/Qwen3-Reranker-0.6B /data/llm/models/Qwen3.5-4B -type f -name '*.safetensors' -printf '%p %s\n'
```

第二条命令应无输出；第三条应看到各模型权重。保留提交清单和下载日志。

## 安装 systemd template

推送更新后，在服务器仓库目录获取它（本次没有替你改服务器仓库）：

```bash
cd /data/llm/a3950x-run-llm
git pull --ff-only
sudo ./scripts/install-systemd-service.sh
systemctl cat 'llm-vllm@.service'
```

安装器只写入 `/etc/systemd/system/llm-vllm@.service`、建立缺少的 `/data/llm` 日志/锁/缓存目录并 reload systemd，不启用或启动任何模型。若同名 unit 已存在，会先创建时间戳备份。

## 查看 profile 并启动

启动模型会占用 Arc Pro B60 显存和系统内存。启动前核对 `free -h`、`systemctl --user status llm-aux-models-download.service`、模型文件完整性，并确保没有其他程序正在占用 GPU。每次只启动一个实例：

```bash
/data/llm/a3950x-run-llm/scripts/serve-model.sh --list
sudo systemctl start llm-vllm@qwen36-27b.service
systemctl status llm-vllm@qwen36-27b.service --no-pager
tail -n 100 /data/llm/logs/vllm-qwen36-27b.log
curl --fail http://127.0.0.1:8000/v1/models
```

切换模型前先停止当前模型：

```bash
sudo systemctl stop llm-vllm@qwen36-27b.service
sudo systemctl start llm-vllm@qwen3-embedding-0.6b.service
```

停止服务会释放模型占用：

```bash
sudo systemctl stop llm-vllm@qwen3-embedding-0.6b.service
```

不要同时 `enable` 多个实例。推荐先手动启动，完成质量、延迟、吞吐、显存、RAM 峰值和稳定性验证，再决定是否设置单一 profile 的开机自启。

## API 类型

- 生成模型：`/v1/chat/completions`；27B 端口 8000，35B 端口 8004，4B 多模态端口 8003。
- Embedding：`/v1/embeddings`，端口 8001。Qwen3 Embedding 的检索查询建议使用任务说明前缀，文档向量不加查询指令；按场景固定前缀并对查询/文档使用对应格式。
- Reranker：`/rerank` 或 `/v1/rerank`，端口 8002；发送 query 与候选 documents。
- 所有 profile 默认只绑定 `127.0.0.1`。远程 agent 使用 SSH tunnel 或已配置认证的反向代理，不要直接暴露未认证端口。

## 之后主要调整哪些参数

1. **`MAX_MODEL_LEN`**：控制 prompt + completion 上下文上限。27B 已测 full-XPU 可重复 25.6K；4 GiB CPU offload 下可重复 41.6K。41K TTFT 约 37–77 秒，长文场景才使用。
2. **`MAX_NUM_SEQS` / 客户端并发**：27B 设置的 server 上限为 8，但实测常规最优折中是客户端并发 4；并发 8 的队列尾延迟较差。
3. **`MAX_NUM_BATCHED_TOKENS`**：影响批处理吞吐与长 prompt 调度。27B 常规用 2048；长上下文/35B 使用 1024。
4. **`GPU_MEMORY_UTILIZATION` / `CPU_OFFLOAD_GB`**：常规 27B 用 .93 / 0，35B 用 .96 / 4；27B 长上下文用 .96 / 4。35B 的 KV cache 余量只有约 .85 GiB，降低上下文或并发优先于继续提高显存比例。
5. **`QUANTIZATION` / `VLLM_XPU_INC_WNA16_BACKEND` / `DTYPE`**：27B/35B 必须按已测组合使用 `inc`、`w4a16`、`float16`。不要删掉该覆盖去依赖模型的 `auto-round` 标签。
6. **`ENFORCE_EAGER`**：长上下文与 27B/35B 已测配置使用 `1`。此前 XPU Graph 在长上下文捕获时造成显著宿主内存压力；不要未经复测开启。
7. **`MIN_AVAILABLE_GIB`**：启动前 `MemAvailable` 门槛，不是内存限额。结合 32 GiB cgroup、加载峰值、系统和其他程序使用量调整；不要将 64 GB 机器直接按 48 GB 给模型。
8. **`RUNNER` / `CONVERT` / `HF_OVERRIDES_JSON` / `CHAT_TEMPLATE`**：任务类型参数。文本生成用 `generate`，embedding/reranker 用 `pooling`；Reranker 的 override/template 与模型配套，不要随意删改。
9. **`HOST` / `PORT`**：服务监听地址与端口。推荐保持 localhost；各 profile 端口仅用于方便识别，GPU 锁意味着服务通常不并行运行。
10. **`LANGUAGE_MODEL_ONLY`**：文本专用模型关闭多模态模块可减少显存；4B 视觉模型须保持 `0`。27B/35B 保持测试时默认值以复现既有结果。

每次只改一个主要参数并记录启动日志、请求集、TTFT、tokens/s、并发、显存、RAM 峰值和稳定性。不要把“可启动”直接当成最佳配置。

## 回退

```bash
sudo systemctl stop llm-vllm@qwen36-27b.service llm-vllm@qwen36-35b-a3b.service \
  llm-vllm@qwen3-embedding-0.6b.service llm-vllm@qwen3-reranker-0.6b.service \
  llm-vllm@qwen35-4b.service
sudo rm /etc/systemd/system/llm-vllm@.service
sudo systemctl daemon-reload
```

如安装器备份了既有 unit，先恢复对应 `.pre-a3950x-run-llm.<时间戳>` 文件再 reload。回退不会删除模型、缓存、日志或取证数据。

## 上游参考

- [vLLM v0.33 pooling models](https://docs.vllm.ai/en/v0.33.0/models/pooling_models/)
- [vLLM v0.33 Qwen3 reranker example](https://docs.vllm.ai/en/v0.33.0/examples/pooling/score/)
- [vLLM v0.33 supported models](https://docs.vllm.ai/en/v0.33.0/models/supported_models/)
- [vLLM v0.33 Intel XPU model matrix](https://docs.vllm.ai/en/v0.33.0/models/hardware_supported_models/xpu/)
- [vLLM XPU WNA16 backend environment variable](https://docs.vllm.ai/en/stable/configuration/env_vars/)
- [vLLM v0.33 INC quantization configuration](https://docs.vllm.ai/en/v0.33.0/api/vllm/model_executor/layers/quantization/inc/)
- [Qwen3-Embedding-0.6B model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- Existing Qwen3.6 test report on server: `/data/llm/tests/qwen36-27b-int4-20261117/REPORT.md`
- Existing context sweep on server: `/data/llm/tests/qwen36-27b-int4-20261117/CONTEXT_LIMIT.md`

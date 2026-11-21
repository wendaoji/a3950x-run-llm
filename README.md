# a3950x 本地大模型运行环境

用于管理 a3950x 上运行本地大模型的启动、停止、状态检查脚本和操作文档。模型权重、缓存、运行环境与运行日志留在服务器 `/data/llm`，不纳入 Git。

## 目录约定

- `scripts/`：通用模型服务入口、systemd 安装脚本。
- `docs/`：架构、模型选择、性能测试与运维说明。
- `docs/runbooks/`：按具体操作编写的运行手册。
- `config/models/`：每个模型独立的非敏感启动参数。
- `examples/`：命令和配置示例。

## 约束

- 当前主模型选择为 Qwen3.6-27B；另有 35B 候选、Embedding、Reranker 和 4B 多模态 profile。
- 默认模型目录为 `/data/llm/models`，运行环境与缓存放在 `/data/llm` 下。
- 运行脚本应使用明确的模型路径和版本，不自动下载、升级依赖或启动压力测试。
- 不提交模型权重、密钥、令牌、机器专属配置、缓存和运行日志。
- 运行前记录显存与系统可用内存；配置内存上限时计入运行时和系统开销。

## 使用

列出启动配置：`scripts/serve-model.sh --list`。部署和调参方法见 [`docs/runbooks/model-profiles.md`](docs/runbooks/model-profiles.md)。启动器只加载本地模型，不自动下载或压力测试。27B/35B 的模型元数据标记 AutoRound，但服务器既有测试通过显式 `--quantization inc` 与 oneDNN W4A16 后端成功加载；启动器按该已测覆盖配置运行。

Qwen 服务监听地址、API key 文件和客户端调用方法见 [`docs/runbooks/api-access.md`](docs/runbooks/api-access.md)。密钥只保存在服务器 `/data/llm/secrets/vllm-api-key`，不提交到 Git。

# API 访问与密钥

Qwen3.6-27B 服务监听 `0.0.0.0:8000`，即接受服务器所有 IPv4 网卡上的连接。该机器有 LAN、Tailscale 和其他隧道接口；不要把端口转发到公网，也不要在不可信网络上传输 API key。当前接口使用 HTTP，Bearer key 本身不加密；跨不可信网络访问应先使用 VPN 或 TLS 反向代理。

## 密钥存放和认证

- 服务器密钥文件：`/data/llm/secrets/vllm-api-key`，归服务用户所有，权限 `0600`。
- 启动器从该文件读取 `VLLM_API_KEY`，不会把密钥写入 profile、Git、服务命令行或日志。
- vLLM 内置 key 认证只覆盖部分路径。项目的 `api_key_auth.RequireApiKey` 中间件会额外保护其他 HTTP 和 WebSocket 路由；未带有效 Bearer key 的请求返回 `401`。CORS `OPTIONS` 预检请求除外。
- 更换 key：停止对应模型服务，原子替换密钥文件并保持 `0600` 权限，然后重启服务。更换后旧 key 立即失效。

## 客户端测试

在可信的客户端终端运行；命令从服务器读取密钥到当前 shell 变量，不会将密钥写入命令历史：

```bash
API_KEY="$(ssh a3950x 'cat /data/llm/secrets/vllm-api-key')"
curl --fail-with-body http://a3950x:8000/v1/chat/completions \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-27b","messages":[{"role":"user","content":"17乘以19等于多少？只给结果。"}],"temperature":0,"max_tokens":256}'
unset API_KEY
```

无 key 的测试请求应返回 `401`：

```bash
curl -i http://a3950x:8000/v1/models
```

## 运维检查

在服务器检查监听地址和服务状态：

```bash
sudo ss -ltnp 'sport = :8000'
sudo systemctl status --no-pager llm-vllm@qwen36-27b.service
```

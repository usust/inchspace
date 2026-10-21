# AI 模型服务配置

## 完善后的开发提示词

请将设置页中写死的 DeepSeek 配置扩展为通用的大模型服务配置，并打通终端 AI 的实际调用链路：

1. 提供 DeepSeek、OpenAI、硅基流动、OpenRouter、Ollama 和自定义服务商选项。预设仅提供默认 Base URL，不内置或锁定模型列表。所有服务商的 Base URL 都可编辑。
2. 使用 OpenAI 兼容协议：在用户填写的 API 根地址后追加 `models` 拉取模型，在同一根地址后追加 `chat/completions` 发起流式对话。保留用户填写的 `/v1`、`/api/v1` 或代理路径，避免重复或丢失路径。
3. 允许输入 API Key，通过 Bearer 鉴权。无鉴权的本地或自托管服务允许留空，且不发送空的 Authorization 请求头。
4. 获取模型后提供选择列表，并支持手动填写模型 ID，以适配不提供模型列表接口的服务。模型 ID 由服务或用户决定。
5. 编辑内容作为草稿；获取模型仅查询草稿地址，不修改当前正在使用的配置。点击“应用配置”才保存服务商、Base URL、模型和输入的 Key。显示当前生效的服务商和模型。
6. 记住各服务商最后应用的地址和模型。密钥按规范化后的完整 API 根地址隔离，继续保存在本机 macOS 钥匙串，不写入 UserDefaults、项目文件或日志。留空保留该地址已有 Key，并提供显式移除入口。
7. 兼容旧的 DeepSeek 模型偏好与钥匙串条目。没有主动应用新配置前，原有用户可继续使用旧配置。
8. 校验 URL 协议、主机和模型 ID。Base URL 不接受内嵌账号密码、查询参数、片段或完整接口路径。查询失败、空列表和协议不兼容时提供明确提示。
9. 编辑服务商、地址或 Key 时取消当前模型查询，并防止过期查询结果覆盖新的选择。服务端模型列表不包含已填写 ID 时保留输入，交由用户决定。
10. 终端 AI 的后续请求使用已应用配置，并保持流式输出、上下文脱敏和命令授权逻辑。请求开始时固定本次配置，避免在等待上下文期间混用不同服务的地址与 Key。
11. 增加针对地址拼接、请求参数、模型解析、配置持久化、旧配置兼容、密钥隔离和应用失败回退的自动化测试。

## 使用方式

在设置的 AI 配置中选择服务商，确认 Base URL，填写 API Key，点击“获取模型”，选择模型或直接输入模型 ID，最后点击“应用配置”。后续终端 AI 请求使用该配置。

Base URL 示例：

| 服务商 | 默认 Base URL |
| --- | --- |
| DeepSeek | `https://api.deepseek.com` |
| OpenAI | `https://api.openai.com/v1` |
| 硅基流动 | `https://api.siliconflow.cn/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Ollama | `http://localhost:11434/v1` |
| 自定义 | 服务商提供的 OpenAI 兼容 API 根地址 |

如果服务地址为 `https://example.com/gateway/v1/`，模型列表请求为 `https://example.com/gateway/v1/models`，聊天请求为 `https://example.com/gateway/v1/chat/completions`。不会自动推断或补上 `/v1`，应按服务商提供的地址填写。

API Key 留空时，优先使用同一地址已经保存的 Key；该地址没有 Key 时以无鉴权方式请求。需要清空已保存 Key 时点击“移除”。修改地址不会把旧地址的 Key 带到新地址。

服务需支持 OpenAI 风格的模型列表及 Chat Completions 流式响应；模型列表不可用时可以手动填写模型 ID。列表可能包含不支持聊天的模型，请选择能够进行流式文本对话的模型。服务商使用其他原生协议时，需要通过 OpenAI 兼容网关接入。

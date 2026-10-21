---
name: "balance"
description: "查询当前模型服务商的实时账户余额或官方 ChatGPT 账号的 Codex 使用额度；API 余额可设置低余额提醒阈值。当用户询问余额、还剩多少钱、额度、充值、余额告警，或要求监控、盯着余额时使用。"
---

# 实时余额

`balance` MCP 服务器跟随当前模型服务商，提供不缓存的账户余额或官方 Codex 使用额度查询。

## 工具

- `get_balance`：实时查询当前服务商。官方 ChatGPT 登录账号读取 Codex 使用额度窗口和重置时间；API 账号读取已配置的余额接口。可选参数 `currency`（如 `CNY`、`USD`）只过滤 API 金额币种。
- `balance_alert`：查看 / 设置 / 清除低余额提醒阈值（`threshold` 传 `null` 表示清除）。

## 使用规则

1. 用户询问余额、剩余额度、还能用多久，或要"看一下余额"时，先调用 `get_balance` 拿到实时数据再回答，不要用历史结果或估算值代替。
2. 呈现结果时保留原始数字与查询时刻。API 余额显示币种和金额；官方 Codex 额度显示剩余百分比、窗口时长与重置时间。额度点数不是美元或人民币余额。
3. 返回值里带 ALERT 提示时，明确告知用户余额已低于阈值、建议充值。
4. 调用失败时转达工具返回的安全错误摘要。API 账号检查网络、当前 provider 的 `base_url`、`env_key` 或凭据；官方账号检查 Codex 登录状态和原生程序是否可用。不要输出密钥、token、账号邮箱或远端错误正文。
5. 用户希望"一直盯着"余额时，建议创建定时任务周期性调用 `get_balance`，仅在低于阈值或查询失败时提醒；创建定时任务前先征得用户同意。
6. 未显式配置 `model_provider` 时使用官方 OpenAI 服务商，忽略残留 custom 段。DeepSeek API 使用 `/user/balance`；其他 API 服务商需显式配置 `BALANCE_URL` 指向实际兼容的余额接口，不将任何平台的凭据自动发送给 DeepSeek。
   自定义服务商名称（例如 `openai_http`）指向官方 `https://chatgpt.com/backend-api/codex`、设置 `requires_openai_auth = true` 且当前为 ChatGPT 登录时，也使用官方额度查询；不能仅凭服务商名称或认证标记把第三方地址视为官方账号。
7. 金额提醒阈值只适用于 API 余额，不套用到官方额度百分比。切换服务商后不能把上一服务商的数据当作当前结果。
8. 用户明确选择官方 ChatGPT 额度、但模型路由使用代理别名时，可通过 Codex Home 下的 `balance-source.json` 指定 `{"source":"chatgpt"}`；仅在当前登录模式为 `chatgpt` 时生效，只影响余额查询，不改变模型路由。

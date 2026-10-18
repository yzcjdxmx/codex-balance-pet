# 余额桌宠 · Codex Balance Pet

一只蹲在 Windows 桌面上的 DeepSeek 鲸鱼女仆。脚下的牌子跟着**当前模型服务商**显示账户余额或 Codex 额度，能拖动、会说话、会眨眼；跑任务时奋笔疾书，闲置久了会蜷起来打盹，13 个形象随手切换。

它同时是一个 **Codex 插件**：在对话里问「余额多少」，AI 就能查到实时数据；Codex 一启动，桌宠自己就被拉起来了。

<p>
  <img src="docs/preview/quota.png" width="170" alt="官方额度模式">
  <img src="docs/preview/idle.png" width="170" alt="API 余额 + 心情">
  <img src="docs/preview/talking.png" width="170" alt="点击冒一句台词">
  <img src="docs/preview/blink.png" width="170" alt="真实闭眼帧">
</p>

<p>
  <img src="docs/preview/working.gif" width="170" alt="跑任务时的四帧写字动画">
  <img src="docs/preview/low.png" width="170" alt="余额低于阈值变橙点 + 难过脸">
  <img src="docs/preview/stats.png" width="170" alt="用量行">
  <img src="docs/preview/error.png" width="170" alt="查询失败">
</p>

> PowerShell 负责 Windows 透明窗口与动画，Node 负责账户查询和只读任务状态查询。无需编译、无 Electron。

---

## ✨ 能做什么

- **实时余额 / 额度**：默认 30 秒后台刷新，查询不阻塞拖动和动画。DeepSeek 之类的 API 账号显示金额；官方 ChatGPT 账号显示 Codex 的 5 小时 / 每周剩余百分比。牌子左侧圆点 **🟢 正常 / 🟠 余额偏低或额度用尽 / 🔴 查询失败**
- **查询状态气泡**：查询时桌宠说「查询中. → 查询中.. → 查询中...」，每 400 毫秒循环；结束时停止动画并显示原本的台词
- **任务写字动画**：检测到正在运行的 Codex 任务后，循环播放四帧写字动画，每帧 160 毫秒；任务结束或中止后恢复所选形象。多个任务和子 Agent 会一起判断，查询余额本身不会触发写字
- **拖动 & 记忆**：按住角色任意位置拖走，位置写进 `pet-state.json`，重启回到原处
- **不抢焦点**：默认开启，点击和拖动时保留当前窗口的输入焦点；右键「不抢焦点」可关闭，选择会被记住
- **点击**：冒一句台词 + 换表情 + 立刻查一次余额
- **13 个形象轮换**：右键「换个形象」按文件名顺序切换，选择会被记住
- **表情**：开心（点赞）、难过（担心脸）、打盹（蜷着睡）有独立素材；余额低于阈值自动切难过；闲置超过阈值自动打盹，头顶的 `Zzz` 缓缓上浮、变大并淡出，约 3 秒循环（任务进行中不睡，写字动画优先）
- **右键菜单**：立即刷新余额 / 账户余额或额度详情（含北京时间重置时间）/ 用量详情 / 打个招呼 / 换个形象 / 不抢焦点 / 回到右下角 / 退出
- **不吃鼠标**：透明区域不挡点击，能直接点到下面的窗口
- **随 Codex 启停**：Codex 启动时插件把桌宠无窗口拉起；Codex 进程消失 15 秒后自动关闭；同时只允许一个实例
- **余额记录**：默认每 30 分钟把金额余额追加一行到 `pet\data\balance-log.csv`（正常退出时补一行），配合 `tools\余额报告.ps1` 生成消耗表格 + 曲线图
- **用量行**（右键开关）：多显示一行「用量 58.8M｜缓存 99%｜12.3k tok/s｜¥1.5/h」。闲置时仍保留 `0 tok/s`；额度文字按实际字体高度排版，刷新期间保留上一次同账户的额度
- **对话里也能用**：`balance` MCP 提供 `get_balance` / `balance_alert`，`balance_pet` MCP 提供 `pet`（start / stop / restart / status）

`tok/s` 是会话日志中近 30 秒已记录的输出 token 数除以 30，包含推理输出，也包含等待工具的时间，并非逐 token 的瞬时生成速度。速度行每 1 秒检查当前日志的少量新增内容并更新；会话目录扫描、历史补读和花费计算仍每 5 秒进行。没有新内容时不重复解析，文字不变时不额外重绘；隐藏用量行后暂停每秒检查。日志尚未写出新用量、或超过 30 秒没有输出时，显示 `0 tok/s` 属于正常情况。大量日志待处理时由低频补读追赶，避免每秒重放历史。读取日志时会保留 UTC 与时区偏移，避免把最新用量误判为数小时前的数据。

## 🚀 快速开始

**环境要求**

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| PowerShell | PowerShell 7（`pwsh`）；查询子进程使用的接口不支持 Windows PowerShell 5.1 |
| Node | 支持 `node:sqlite` 的 Node 运行时；脚本优先寻找 Codex 自带运行时 |
| Codex | Codex 桌面版或 CLI，并且已经登录（读的是它自己的配置与凭据） |

**三步装上**

```powershell
# 1) 克隆到任意目录（路径别带特殊字符就行）
git clone https://github.com/yzcjdxmx/codex-balance-pet.git
cd codex-balance-pet

# 2) 安装：把桌宠和插件放进 %USERPROFILE%\.codex，并启动桌宠
pwsh -NoProfile -File tools\install.ps1

# 3) 在 Codex 的插件 / 市场面板里添加本地市场 %USERPROFILE%\.codex\local-marketplaces\balance
#    再安装 balance（实时余额）插件
```

装好之后：Codex 一起来桌宠就在角落里；对话框里问「余额多少」「余额低于 20 元提醒我」都能用。

不想等 Codex，想现在就看一眼：双击 `pet\启动余额桌宠.vbs`。这个入口通过 Windows 脚本宿主隐藏启动，不弹出命令行窗口；原来的 `.cmd` 入口保留用于兼容旧调用。

**只想单独跑桌宠、不装插件**：直接运行 `pet\balance-pet.ps1` 也行，它会自己读 `~\.codex\config.toml` 里的服务商。

自定义配置目录：`pwsh -NoProfile -File tools\install.ps1 -CodexHome "D:\CodexHome"`。安装器会把所选目录传给启动进程；以后从自定义目录运行时，也请设置 `CODEX_HOME`。只复制文件、不重启桌宠可加 `-NoRestart`，更新会保留位置、形象选择和已有余额记录。

## 📁 仓库结构

```
codex-balance-pet\
├── pet\                        桌宠本体
│   ├── balance-pet.ps1           主程序：窗口、动画、菜单、刷新循环
│   ├── account-client.ps1        调 Node 查询模块 + 把结果转成显示文本
│   ├── usage-reader.ps1          读 Codex 会话日志，算 token 用量与速度
│   ├── task-activity.ps1         任务活动指示（正在干活 / 空闲）
│   ├── task-activity-store.mjs   只读查询 Codex 的任务状态数据库
│   ├── pet-host.ps1              常驻 MCP 服务：被插件拉起，顺带提供 pet 工具
│   ├── winless-launch.ps1        无控制台启动器（CreateProcess + CREATE_NO_WINDOW）
│   ├── window-interaction.ps1    窗口与右键菜单的不抢焦点行为
│   ├── start-pet.ps1 / 启动余额桌宠.vbs   无窗口手动启动入口（另保留 .cmd）
│   └── assets\                   立绘 PNG 与四帧写字图集 pet-working-atlas-v1.png
├── plugin\                     Codex 插件
│   ├── .agents\plugins\marketplace.json     本地插件市场定义
│   └── plugins\balance\
│       ├── .codex-plugin\plugin.json        插件清单（名称、图标、默认提问）
│       ├── .mcp.json                        balance MCP 服务定义（install 时补上 balance_pet）
│       ├── server.mjs                       MCP 服务：get_balance / balance_alert
│       ├── account.mjs                      余额查询核心（桌宠与插件共用同一份逻辑）
│       └── skills\balance\SKILL.md          教 AI 怎么用这些工具的技能文件
├── tools\
│   ├── install.ps1              安装 / 更新（幂等）
│   ├── 余额报告.ps1             余额日志 -> 消耗表格 + PNG 曲线图
│   ├── extract-stickers.ps1     从离线网页抓素材图
│   └── prepare-pet-art.ps1      抠白底 / 去水印 / 裁边 / 缩放成 320x400
├── docs\preview\               README 用的效果截图
├── tests\                      任务生命周期与安装路径测试
└── LICENSE
```

## 💰 余额 / 额度是从哪来的

桌宠不做任何猜测，每次刷新都重新读一遍 `~/.codex/config.toml` 的顶层 `model_provider` 与当前认证。

| 账号类型 | 数据来源 | 显示 |
|---|---|---|
| 官方 ChatGPT 登录 | Codex 的 `account/rateLimits/read`（不调用模型推理，不消耗额度） | 5 小时 / 每周剩余百分比 + 北京时间重置时间 |
| DeepSeek API | `GET /user/balance` | ¥ 金额 |
| 其他 API 平台 | 需要显式设 `BALANCE_URL` 指向兼容的余额接口 | 该接口返回的金额 |

- 没有显式配置 `model_provider` 时按官方 OpenAI 处理，不会误选残留的 `custom` 段
- 自定义名称（如 `openai_http`）指向官方 `https://chatgpt.com/backend-api/codex`，且启用 `requires_openai_auth = true`、当前以 ChatGPT 登录时，同样读取官方额度，无需配置金额余额接口；第三方地址不会仅凭名称被认作官方账号
- 凭据只在 Node 进程里读，脚本之间不互相传；启动器里连 stderr 都不回显，避免第三方报错带出密钥
- 已设置的低余额阈值只对**同一币种**的金额生效，不会套到官方额度百分比上
- 官方额度百分比**不会**写进金额日志，避免把两种口径混在一起

任务状态只读 Codex 的任务数据库与会话日志事件，不修改数据库。后台查询与窗口刷新分开运行；历史遗留的未结束事件会与当前数据库状态校验，避免一直停留在写字状态。

## 🎨 换形象 / 加形象

形象就是 `pet\assets\` 里的 PNG，**加形象不用改代码**——把处理好的图命名成 `pet-look-13.png` 丢进去，重启就会出现在轮换里。

| 文件名 | 作用 |
|---|---|
| `pet-base.png` | 默认形象 |
| `pet-look-01.png` … `pet-look-12.png` | 可轮换形象，右键「换个形象」按文件名顺序切换 |
| `pet-happy.png` / `pet-sad.png` / `pet-sleepy.png` | 对应心情用真图换脸 |
| `pet-working-atlas-v1.png` | 透明背景的 2×2 四帧写字图集，按行从左到右播放 |
| `pet-normal.png` / `pet-blink.png` | 默认形象的配套睁眼 / 闭眼帧，眨眼直接切图，不再压扁身体 |
| `pet-look-13-normal.png` / `pet-look-13-blink.png`（可选） | 自定义形象的配套表情帧，不作为独立形象参与轮换；缺少闭眼帧时保留当前形象 |

从网上下到的表情包变成可用立绘：

```powershell
# 1) 从离线保存的网页里提图并下载（自动带 Referer 绕防盗链）
pwsh -NoProfile -File tools\extract-stickers.ps1 -Html "页面.html" -OutDir "素材\某某表情包" -Limit 40

# 2) 抠底 -> 去水印/气泡（只保留主体连通块）-> 裁边 -> 等比放进 320x400
pwsh -NoProfile -File tools\prepare-pet-art.ps1 -Source "素材\...\raw-025.jpg" -Name base -RemoveBackground
```

## ⚙️ 参数与用法

```powershell
pwsh -NoProfile -File pet\balance-pet.ps1
pwsh -NoProfile -File pet\balance-pet.ps1 -RefreshSeconds 60    # 刷新间隔（默认 30 秒）
pwsh -NoProfile -File pet\balance-pet.ps1 -Preview              # 只渲染合成图，不开窗口
pwsh -NoProfile -File pet\balance-pet.ps1 -Headless             # 只查一次余额，看结果
```

`-IdleSleepSeconds` 为闲置打盹阈值（默认 150 秒）；任务进行中不会打盹，设一个很大的值即可关闭打盹。

看消耗报告：

```powershell
pwsh -NoProfile -File tools\余额报告.ps1            # 全部记录
pwsh -NoProfile -File tools\余额报告.ps1 -Days 1    # 只看最近一天
```

输出区间消耗、逐小时消耗，以及一张 PNG 曲线图（默认写到 `docs\reports\`）。

运行离线测试（不读取实际账户凭据、不启动桌宠）：

```powershell
pwsh -NoProfile -File tests\task-activity.test.ps1
pwsh -NoProfile -File tests\install.test.ps1
pwsh -NoProfile -File tests\window-interaction.test.ps1
pwsh -NoProfile -File tests\sprite-frames.test.ps1
pwsh -NoProfile -File tests\launcher.test.ps1
```

## ❓ 常见问题

**桌宠没出现？**
先看是不是被单实例锁挡了：任务管理器里搜 `balance-pet.ps1`，多于一个就全结束再启动一次。再看 `%TEMP%\balance-pet-status.json`，那里写了 pid、当前账户类型和最近一次错误。

**牌子上是「查询失败」？**
右键「账户余额 / 额度详情」看具体原因。API 账号检查当前服务商的凭据和余额接口配置；官方账号检查 Codex 是否登录、原生程序是否可用。

**余额一直是 0 或显示别的账户？**
在 `~/.codex/config.toml` 里显式设 `model_provider`，或者给该 provider 设 `BALANCE_URL`。没设 provider 时会按官方 OpenAI 处理。

**不想让它记余额日志？**
删掉 `pet\data\balance-log.csv` 并给桌宠所在目录设只读，或直接把 `-LogIntervalSeconds` 调得足够大。配额/额度模式本来就不写这个日志。

**立绘文件被占用，改不了？**
先退出桌宠（右键退出，或 `tools\install.ps1 -NoRestart` 前后手动结束进程）。运行中其实是能换 PNG 的，只是某些编辑器会锁文件。

## 🗺 还没做 / 可以一起改进的

- 跨平台（macOS / Linux）——现在的窗口层是 Win32 的 `UpdateLayeredWindow`

## ⚖️ 素材来源与版权

- **代码**：MIT，见 [LICENSE](LICENSE)
- **立绘**：`pet\assets\` 里的表情素材是从网上流传的 DeepSeek 表情包（知乎帖《想求一些 DeepSeek 表情包？》里的图片）抠底加工而来，**非官方素材**，版权属于原作者。这里只作为示例形象随仓库提供；**若权利人提出异议，会立刻删除并换成占位图**。你也可以完全替换成自己的图（见上面「换形象」）。
- **写字动画**：四帧图集参考同一角色形象生成，属于本项目的非官方示例素材。
- **眨眼帧**：`pet-blink.png` 沿用原默认立绘的闭眼表情；配套的 `pet-normal.png` 用 ImageGen 内置工具生成后缩放为 320×400，提示词为「只将默认立绘的闭眼改成蓝色睁眼，保持人物、姿势、服饰、构图与透明背景一致」。这两帧只用于默认形象。
- 本项目是个人作品，与 OpenAI、DeepSeek 均无关联，未获得其背书；「Codex」「ChatGPT」「DeepSeek」等名称与标识归各自权利人所有。
- 余额数据只在你本机读取、只用于本地显示，不会上传到任何地方。

## 📄 License

[MIT](LICENSE) © 2026 yzcjdxmx

---

## English (short)

**Codex Balance Pet** — a per-pixel-transparent Windows desktop pet (pure PowerShell) that shows your live API balance or your Codex rate-limit quota on a little sign, plus a Codex plugin (two MCP servers: `balance`, `balance_pet`) so you can just ask the agent "how much credit do I have left?".

```powershell
git clone https://github.com/yzcjdxmx/codex-balance-pet.git
cd codex-balance-pet
pwsh -NoProfile -File tools\install.ps1     # copies pet + plugin into %USERPROFILE%\.codex, starts the pet
# then enable the "balance" plugin from the local marketplace inside Codex
```

Requires Windows 10/11, PowerShell 7, Node with `node:sqlite` support, and a logged-in Codex. The pet plays a four-frame writing animation while tasks run and dozes off after 150s idle (never while a task is running). Refreshing shows animated dots in a speech bubble while retaining the previous quota display. Artwork in `pet\assets\` is bundled from unofficial DeepSeek sticker packs and will be removed on request. Code is MIT licensed.

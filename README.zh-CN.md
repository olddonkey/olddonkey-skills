<div align="center">

# Olddonkey Skills

**从真实跑过、摔过、修好过的工作流中提炼出的开源 [Agent Skills](https://agentskills.io)。**

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [简体中文](./README.zh-CN.md)

</div>

---

目前包含三个 Claude Code skill，外加一个内含两个工程 skill 的 Cursor Plugin：

- [`implementation-loop`](#implementation-loop) —— 把实现交给 **Codex、grok 或 cursor-agent**，但不把判断交出去：Claude 亲自审查真实 diff、跑全量测试门禁，只发布自己敢签名的改动。实现后端是一个可选档位，三者的审查与发布纪律完全一致。
- `engineering-mode` —— 目标先行的工程主导模式：先调查、定设计、写计划，再逐单元驱动 `implementation-loop`。
- [`cursor-implementation-loop`](#cursor-implementation-loop) —— Cursor Plugin 内含计划先行的实现循环和目标先行的 `cursor-engineering-mode` 包装器；父 agent 负责 review / 门禁 / 发布，implementer 子 agent 写代码。
- [`web-slides`](#web-slides) —— 把素材 / 提纲做成点击驱动的 16:9 HTML 幻灯片，用于现场放映；内置 24 套主题 + 演讲者窗口，投屏时口播稿对观众不可见。

## 安装

### 插件市场（推荐）

在 Claude Code 里先添加一次 marketplace，再按需安装需要的 skill：

```text
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install implementation-loop@olddonkey-skills
/plugin install engineering-mode@olddonkey-skills
/plugin install web-slides@olddonkey-skills
/reload-plugins
```

由于实现循环现在支持 Codex、grok 和 cursor-agent 后端，这两个插件已去掉 `codex-` 前缀并改用新名称。已安装旧 Codex 前缀插件 ID 的用户应先卸载旧 ID，再安装 `implementation-loop` 和 `engineering-mode`。

`engineering-mode` 依赖 `implementation-loop`；Codex 后端需要已登录的 `codex` CLI，不再需要额外的 Claude Code 插件，见下方[环境准备](#环境准备)。`web-slides` 除了生成的幻灯片项目需要 Node.js 之外没有额外依赖。

### 手动安装

拷贝进个人 skills 目录：

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
mkdir -p ~/.claude/skills
cp -R /tmp/olddonkey-skills/skills/<skill-name> ~/.claude/skills/
```

或用软链接连接 clone，pull 即升级：

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
mkdir -p ~/.claude/skills
ln -s ~/Documents/olddonkey-skills/skills/<skill-name> ~/.claude/skills/<skill-name>
```

如果你在 Claude Code 会话运行期间第一次创建 `~/.claude/skills` 顶层目录，请重启会话，让新目录被发现。若你的 agent 不跟随 skills 目录里的软链接，请使用拷贝方式，并在 `git pull` 后重新拷贝。

### Cursor Plugin

在 Cursor 中，一行安装器会把独立 skill 和两个 agents 裸拷贝到 Cursor 可发现的目录。适用于当前所有 build，也适用于个人电脑或临时 / 公司电脑——只写你的 home 目录：

一行安装（默认裸拷贝）：

```bash
curl -fsSL https://raw.githubusercontent.com/olddonkey/olddonkey-skills/main/install-cursor.sh | bash
```

`--copy` 仍可作为默认模式的显式别名。对于仍会扫描 `plugins/local` 的旧版 Cursor，可用 `--link` 选择 managed-checkout 软链接：

```bash
curl -fsSL https://raw.githubusercontent.com/olddonkey/olddonkey-skills/main/install-cursor.sh | bash -s -- --link
```

想使用真正的插件形态？在 Cursor 的 Customize → Plugins 页面按 "+ Add"，选择 `$OLDDONKEY_SKILLS_DIR`（默认：`~/olddonkey-skills`）；该 checkout 根目录包含 `.cursor-plugin/marketplace.json`，它会注册 `cursor-implementation-loop` 插件。然后删除独立拷贝，避免重复加载。

也可以手动安装本地插件软链接：

```bash
git clone https://github.com/olddonkey/olddonkey-skills
mkdir -p ~/.cursor/plugins/local
ln -s "$(pwd)/olddonkey-skills/cursor-implementation-loop" \
      ~/.cursor/plugins/local/cursor-implementation-loop
# 重启 Cursor，或执行 "Developer: Reload Window"
```

装完自检一次：

```bash
bash ~/.cursor/plugins/local/cursor-implementation-loop/skills/cursor-implementation-loop/scripts/gate-selftest.sh
# 期望输出：selftest: PASS (122 checks)
```

若想手动复现默认安装，请裸拷贝文件——两步都要做：

```bash
mkdir -p ~/.cursor/skills ~/.cursor/agents
cp -R olddonkey-skills/cursor-implementation-loop/skills/cursor-implementation-loop \
      ~/.cursor/skills/
cp olddonkey-skills/cursor-implementation-loop/agents/*.md ~/.cursor/agents/
```

软链安装的卸载：`rm ~/.cursor/plugins/local/cursor-implementation-loop`，再删掉 clone。Teams / Enterprise 也可 Dashboard → Plugins → Import from Repo。清单见 [`.cursor-plugin/marketplace.json`](./.cursor-plugin/marketplace.json)。

## 计划先行 vs 目标先行

**计划先行（现有行为不变）：**先审阅并批准计划，再直接调用实现循环：`使用 implementation-loop 逐单元实现 PLAN.md。`

**目标先行：**只给 engineering mode 一个结果目标；它会调查根因、选定设计、写出计划，再驱动同一套循环。Codex：`使用 engineering-mode 修复 webhook 重放导致的重复履约。` Cursor：`使用 cursor-engineering-mode 修复 webhook 重放导致的重复履约。`

Codex 侧依赖链：`engineering-mode` → `implementation-loop` → 已登录的 `codex` CLI。Cursor 侧的 `cursor-engineering-mode` 已内置于 `cursor-implementation-loop` 插件，无需单独安装；现有安装更新后即可获得：重新运行一行安装命令，或在 managed checkout 中执行 `git pull`。

---

## implementation-loop

**把实现交给 Codex、grok 或 cursor-agent，但不把判断交出去。**

实现者负责实现并跑聚焦测试；Claude 亲自审查真实 diff、跑全量门禁，只发布自己敢签名的改动。

**后端是一个可选档位。** 默认是 Codex（见下方环境准备）；无论哪个后端实现，都是同一套循环、同样的审查与门禁纪律。每个后端的 git 与发布边界机制不同，各有独立的 runtime 文档——首次派发前请先读所选后端的：

- **grok** —— fail-closed 自定义沙箱、linked-worktree 定位、按机器的 tuple allowlist。见 [`references/runtime-grok.md`](./skills/implementation-loop/references/runtime-grok.md)。
- **cursor-agent** —— git-less-copy 架构：实现者在一个无 `.git`、禁网络的沙箱拷贝里改文件，编排者再把捕获的 patch 应用到真仓库（绝不带 `--force`/`--yolo`，那会绕过沙箱）。见 [`references/runtime-cursor.md`](./skills/implementation-loop/references/runtime-cursor.md)。

两者的默认实现模型都是 Grok 4.6 / `xhigh`，但 `--model` 在每个后端都是透传的——cursor-agent 尤其可以用到账号目录里的全部模型（Claude、GPT-5.x、Gemini、Composer、各档 Grok），其中 effort 档位是写在模型 id 里的。

### 环境准备

循环通过 `codex exec` 直接调用 Codex CLI，不需要额外的 Claude Code
插件。如尚未安装或登录，可执行：

```bash
npm install -g @openai/codex
codex login
```

你可以使用 ChatGPT 账号（包括免费版）或 OpenAI API key 登录。已经装过？先用 `codex --version` 检查版本；若刚发布的新模型不可用，CLI 过旧是常见原因：

```bash
codex update
```

### 启动第一个循环

在目标仓库中打开 Claude Code，然后直接说：

> 使用 implementation-loop 实现 PLAN.md 的第 1 项。停在 PR；门禁使用 baseline；review 深度为 standard；进入下一单元前先确认；model 和 effort 继承我的 Codex 配置。

自然语言触发同时适用于插件市场和手动安装。第一次运行时，Claude 会在派发前说明最终采用的控制项，让成本、自动化程度和发布边界都清清楚楚。

### 循环如何工作

**拆单元 → 派发 → review → 迭代 → 测试门禁 → 发布 → 下一个**

1. Claude 把 plan、spec 或 TODO 拆成一个完整、可 review 的工程单元。
2. Codex 在工作树中实现，并且只运行派发时指定的聚焦测试。
3. Claude 阅读真实 diff、检查整个工作树，再次派发具体问题；只有 resume 通过规定的真实后端矩阵后才复用同一个 Codex exact session，否则通过新的 prompt 携带上下文。
4. Claude 亲自跑全套测试，并按照选定的门禁策略判定结果。
5. Claude 停在配置好的边界：工作树、commit、PR，或者经过明确授权的 merge。

Codex 的总结只是检查地图，不是改动正确的证据；diff 和测试门禁才是证据。

### 为什么使用它

- **证据优先的 review。** 清单专门检查委派改动中常被普通 review 漏掉的问题：被改弱的测试、默认值导致的静默回归、无法发布的 gitignore 文件、悄悄新增的依赖，以及被软化的强制边界。
- **有边界的自动化。** 七个控制项决定循环可以走多远、review 多深、修复由谁实现，以及门禁变红时怎么办。每个仓库只确定一次，不必每个单元重新争论。
- **把昂贵的经验编码一次。** 工作流明确区分聚焦测试和全量门禁，通过保留的 transcript 识别卡死的前台任务，并覆盖有界中断与清理孤儿进程。
- **两个附带工具。** [`codex-dispatch.sh`](./skills/implementation-loop/scripts/codex-dispatch.sh) 通过 plain `codex exec` 固定策略、维护循环状态并校验 banner；[`run-gate.sh`](./skills/implementation-loop/scripts/run-gate.sh) 保留测试套件的真实 exit code，并支持与基线失败项对比。

完整工作流见 [`SKILL.md`](./skills/implementation-loop/SKILL.md)。

### 控制项

Skill 为首次运行准备了保守选择；只需要指定你想改变的部分：

| 控制项 | 常见首次选择 | 用途 |
| --- | --- | --- |
| 停点 | `pr` | 把改动留在工作树、提交 commit、创建 PR，或在明确授权后 merge |
| 派发模式 | `implement` | 选择实际实现或只读调查 |
| 门禁策略 | `baseline` | 要求不新增非 flaky 失败、要求零失败，或对无运行时影响的改动明确跳过门禁 |
| 门禁变红 | `stop` | 停下来交给用户，或把失败送回 Codex 做有限次数的迭代 |
| Review 深度 | `standard` | 选择 light、standard 或带独立复核的 deep review |
| 节奏 | `confirm` | 在单元之间确认，或在发布策略安全时自动继续 |
| 修复通道 | `codex` | bug 修复默认作为新单元交给 Codex；可选允许琐碎机械改动直接修 |

除非为某次任务明确覆盖，否则 model 和 effort 会继承用户自己的 Codex 配置。

### 兼容性与限制

- 指令采用开放的 `SKILL.md` 格式。Claude marketplace 承载这个 skill，而 Codex 后端通过 plain `codex exec` 直接调用已登录的 `codex` CLI。
- 其他 agent 可以使用已附带的 grok、cursor-agent 适配器，或实现同一派发契约的新适配器。
- 脚本需要 Bash、Python 3.11+、所选后端的 CLI 和常见 Unix 命令行工具；开发环境为 macOS。
- Codex 与 Claude Code 使用同一份 checkout 和本机环境，其用量计入你的 ChatGPT 或 API 限额；详见 [Codex 定价](https://developers.openai.com/codex/pricing)。

---

## cursor-implementation-loop

**内含两个 skill 的 Cursor Plugin：计划先行的 `cursor-implementation-loop`，以及目标先行的 `cursor-engineering-mode` 包装器。**

同一套 review-gated 循环，适配 Cursor 原生子 agent：**父 agent** 负责规划、diff review、全量测试门禁和发布；专用 **implementer** 子 agent 写代码。[`run-gate.sh`](./cursor-implementation-loop/skills/cursor-implementation-loop/scripts/run-gate.sh) 与 Codex skill 逐字共享。

Codex 侧的三项硬保证（implementer 只读 git、派发前 fail-closed 检查、每次派发披露 model）在 Cursor 没有原生等价物，因此改为流程约束。无人值守使用前请先阅读 [`references/cursor-runtime.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/references/cursor-runtime.md)。

### 怎么教 agent 用

先完成 [Cursor Plugin](#cursor-plugin) 安装，在**目标仓库**里打开 Cursor，然后用自然语言或显式斜杠命令触发。父 agent 应加载 [`SKILL.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md) 并按它执行——你不必把整套流程再说一遍。

显式调用：

```text
/cursor-implementation-loop 按 docs/my-plan.md 逐单元推进。
停在 PR；门禁用 baseline；review 深度 standard；进入下一单元前先确认。
```

自然语言（也会选中该 skill）：

> 用 cursor-implementation-loop 实现 PLAN.md 的第 1 项。编码交给 implementer 子 agent；你亲自审查真实 diff、跑全量门禁，并开 PR。进入下一单元前先确认。

第一次运行时，父 agent 会先问一个 kickoff 问题（停点、节奏、用哪个 implementer / model），再进入循环。建议在 `agents/loop-implementer.md` 里 pin 一个与父 agent 不同的 model——自带的 `model: inherit` 只是占位，等于放弃模型配对价值。

### Agent 必须怎么做

**拆单元 → 派发 → review → 迭代 → 测试门禁 → 发布 → 下一个**

1. **父 agent** 把 plan / spec / TODO 拆成一个完整、可 review 的单元，派发前先定设计。
2. **父 agent** 用完整 unit contract 前台派发 `loop-implementer`（为何改、改什么、跑哪些聚焦测试、不许碰什么）。implementer 不得碰 git，默认也不得跑全量测试套件。
3. **父 agent** 阅读真实 diff 和整个工作树；implementer 的汇报只是主张，不是证据。问题通过**恢复同一个 agent** 送回迭代。
4. **父 agent** 用 `scripts/run-gate.sh` 亲自跑全套测试，并按选定门禁策略判定。
5. **父 agent** 停在配置好的边界：工作树、commit、PR，或经明确授权的 merge。禁止直推默认分支。

review 或门禁发现的 bug 也要作为新单元交给 implementer——父 agent 不要为了「更快」偷偷手改。

### 控制项（与 Codex skill 同一套 dial）

| 控制项 | 常见首次选择 | 用途 |
| --- | --- | --- |
| 停点 | `pr` | 工作树、commit、PR，或授权后的 merge |
| 派发模式 | `implement` | 实际实现或只读调查 |
| 门禁策略 | `baseline` | 不新增非 flaky 失败、零失败，或对无运行时影响的改动跳过 |
| 门禁变红 | `stop` | 停给用户，或有限次数迭代 |
| Review 深度 | `standard` | light / standard / 独立 deep（`loop-independent-reviewer`） |
| 节奏 | `confirm` | 单元间确认，或在发布策略允许时连续推进 |
| 修复通道 | `implementer` | 修复默认走 implementer；可选允许琐碎机械一行改动 |
| Implementer 模型 | 已 pin 的变体 | 由用户决定——不要静默假定 `inherit` |

完整工作流：[插件 README](./cursor-implementation-loop/README.md) · [`SKILL.md`](./cursor-implementation-loop/skills/cursor-implementation-loop/SKILL.md) · [cursor-runtime.md](./cursor-implementation-loop/skills/cursor-implementation-loop/references/cursor-runtime.md)。

---

## web-slides

**点击驱动的 16:9 HTML 幻灯片，用于现场放映 —— 电影感，且刻意不像 AI 做的。**

给它素材、提纲或一堆要点，它会先和你一起做内容规划（章节切分、每步屏幕内容、信息池），在一个 checkpoint 里对齐 outline / 主题 / 素材 / 开发模式，然后产出一个 Vite + React + TypeScript 项目：每次点击推进一个逻辑节拍，每一步独占整屏。

- **演讲者窗口。** 按 `P` 打开独立的演讲者窗口：当前步 + 下一步口播稿、实时 slide 预览、计时器，通过 `BroadcastChannel` 与主窗口联动。在 Meet / Zoom 里只共享主 slide 窗口，观众就永远看不到口播稿 —— 单屏也成立。按 `N` 是排练用的备注浮层（会被投屏捕获，仅自己练时用）。
- **24 套内置主题**，每套有独立的设计 DNA（`theme.json` + `tokens.css`），配合反 AI 味设计方法论：内容驱动动画、逐步揭示、电影感留白。
- **硬性协作节点。** 第 1 章永远在主线程完成并经人工验收，之后才按逐章 / 顺序 / 并行模式开发其余章节。
- 适用：技术分享、keynote、产品演示、pitch deck、教学课件、项目复盘。

自然语言触发 ——「帮我把这份素材做成 slides」—— 或显式调用 `/web-slides`。详见 [README](./skills/web-slides/README.md) · [SKILL.md](./skills/web-slides/SKILL.md)。

由 ConardLi 的 [garden-skills](https://github.com/ConardLi/garden-skills)（MIT）改造而来：去掉口播 / TTS / 录屏流水线，在同一套视觉方法论与主题系统之上新增现场放映能力（每步演讲备注、演讲者窗口）。

## 更新

通过插件市场安装时，在 Claude Code 里执行：

```text
/plugin marketplace update olddonkey-skills
/plugin update implementation-loop@olddonkey-skills
/plugin update engineering-mode@olddonkey-skills
/plugin update web-slides@olddonkey-skills
/reload-plugins
```

通过 clone 安装时执行 `git pull`；若使用拷贝方式，还需要重新拷贝 skill。

## 许可证

[MIT](./LICENSE)。`web-slides` 由同为 MIT 协议的 [garden-skills](https://github.com/ConardLi/garden-skills) 改造而来，skill 内保留上游署名。

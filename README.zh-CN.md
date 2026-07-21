<div align="center">

# Olddonkey Skills

**把实现交给 Codex，但不把判断交出去。**

从真实跑过、摔过、修好过的工作流中提炼出的开源 [Agent Skills](https://agentskills.io)。

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [简体中文](./README.zh-CN.md)

</div>

---

当前主打的 [`codex-implementation-loop`](./skills/codex-implementation-loop)，让 Claude Code 把实现交给 Codex，同时把 diff review、全量测试门禁和发布决策牢牢留在 Claude 手里。

**Codex 负责实现并跑聚焦测试；Claude 亲自审查真实 diff、跑全量门禁，只发布自己敢签名的改动。**

## Skills 一览

| Skill | 做什么 |
|---|---|
| [`codex-implementation-loop`](./skills/codex-implementation-loop) | 带审查门禁的实现循环：把编码单元派给 Codex，审查 diff，跑全量测试门禁，以 PR 交付。 |
| [`web-slides`](./skills/web-slides) | 把素材 / 提纲做成点击驱动的 16:9 HTML 幻灯片，用于现场放映 —— 内置 24 套主题 + 反 AI 味设计方法论 + 演讲者窗口（按 `P`：独立窗口显示口播稿 + 实时预览 + 计时器，投屏只共享主 slide 窗口即可对观众隐藏口播稿）。由 ConardLi 的 [garden-skills](https://github.com/ConardLi/garden-skills)（MIT）改造而来。 |

安装 `web-slides`：

```text
/plugin install web-slides@olddonkey-skills
```

## 快速开始

### 1. 安装

在 Claude Code 里依次执行：

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install codex-implementation-loop@olddonkey-skills
/reload-plugins
/codex:setup
```

`/codex:setup` 来自官方 [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc)，用于检查 Codex CLI 是否已安装并登录。该插件要求 Node.js 18.18 或更高版本；若本机有 npm，它可以主动提出帮你安装 CLI。也可以手动完成：

```bash
npm install -g @openai/codex
codex login
```

你可以使用 ChatGPT 账号（包括免费版）或 OpenAI API key 登录。已经装过？先用 `codex --version` 检查版本；若刚发布的新模型不可用，CLI 过旧是常见原因：

```bash
codex update
```

### 2. 启动第一个循环

在目标仓库中打开 Claude Code，然后直接说：

> 使用 codex-implementation-loop 实现 PLAN.md 的第 1 项。停在 PR；门禁使用 baseline；review 深度为 standard；进入下一单元前先确认；model 和 effort 继承我的 Codex 配置。

自然语言触发同时适用于插件市场和手动安装。第一次运行时，Claude 会在派发前说明最终采用的控制项，让成本、自动化程度和发布边界都清清楚楚。

## 循环如何工作

**拆单元 → 派发 → review → 迭代 → 测试门禁 → 发布 → 下一个**

1. Claude 把 plan、spec 或 TODO 拆成一个完整、可 review 的工程单元。
2. Codex 在工作树中实现，并且只运行派发时指定的聚焦测试。
3. Claude 阅读真实 diff、检查整个工作树，再把具体问题送回同一个 Codex thread 迭代。
4. Claude 亲自跑全套测试，并按照选定的门禁策略判定结果。
5. Claude 停在配置好的边界：工作树、commit、PR，或者经过明确授权的 merge。

Codex 的总结只是检查地图，不是改动正确的证据；diff 和测试门禁才是证据。

## 为什么使用它

- **证据优先的 review。** 清单专门检查委派改动中常被普通 review 漏掉的问题：被改弱的测试、默认值导致的静默回归、无法发布的 gitignore 文件、悄悄新增的依赖，以及被软化的强制边界。
- **有边界的自动化。** 七个控制项决定循环可以走多远、review 多深、修复由谁实现，以及门禁变红时怎么办。每个仓库只确定一次，不必每个单元重新争论。
- **把昂贵的经验编码一次。** 工作流明确区分聚焦测试和全量门禁，按事件流识别卡死任务，并覆盖取消任务与清理孤儿进程。
- **两个附带工具。** [`codex-dispatch.sh`](./skills/codex-implementation-loop/scripts/codex-dispatch.sh) 自动定位当前 companion 运行时并展示派发设置；[`run-gate.sh`](./skills/codex-implementation-loop/scripts/run-gate.sh) 保留测试套件的真实 exit code，并支持与基线失败项对比。

完整工作流见 [`SKILL.md`](./skills/codex-implementation-loop/SKILL.md)。

## 控制项

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

## 手动安装

以下方式只替代“快速开始”中两条 `olddonkey-skills` 插件市场命令；仍然需要官方 Codex 插件和已登录的 Codex CLI。

### 拷贝进个人 skills 目录

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
mkdir -p ~/.claude/skills
cp -R /tmp/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/
```

### 用软链接连接 clone，pull 即升级

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
mkdir -p ~/.claude/skills
ln -s ~/Documents/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/codex-implementation-loop
```

如果你在 Claude Code 会话运行期间第一次创建 `~/.claude/skills` 顶层目录，请重启会话，让新目录被发现。若你的 agent 不跟随 skills 目录里的软链接，请使用拷贝方式，并在 `git pull` 后重新拷贝。

## 兼容性与限制

- 指令采用开放的 `SKILL.md` 格式，但当前运行时和附带的派发脚本只针对 **Claude Code + 官方 [OpenAI Codex 插件](https://github.com/openai/codex-plugin-cc)** 构建与测试。
- 其他 agent 可以复用这套工作流，但需要为自己的派发运行时编写适配层；`codex-dispatch.sh` 目前会在 Claude Code 的插件目录中寻找 `codex-companion`。
- 脚本需要 Bash、Node.js 和常见 Unix 命令行工具；开发环境为 macOS。
- Codex 与 Claude Code 使用同一份 checkout 和本机环境，其用量计入你的 ChatGPT 或 API 限额；详见 [Codex 定价](https://developers.openai.com/codex/pricing)。

## 更新

通过插件市场安装时，在 Claude Code 里执行：

```text
/plugin marketplace update olddonkey-skills
/plugin update codex-implementation-loop@olddonkey-skills
/reload-plugins
```

通过 clone 安装时执行 `git pull`；若使用拷贝方式，还需要重新拷贝 skill。

## 许可证

[MIT](./LICENSE)

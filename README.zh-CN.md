<div align="center">

# Olddonkey Skills

**从真实使用中提炼的开源 [Agent Skills](https://support.claude.com/en/articles/12512176-what-are-skills) 集合，面向 Claude Code 及一切支持 `SKILL.md` 格式的 AI 编程代理。**

[![License: MIT](https://img.shields.io/github/license/olddonkey/olddonkey-skills?style=flat-square&color=blue)](./LICENSE)
[![Skills count](https://img.shields.io/badge/skills-1-orange?style=flat-square)](#skills)
[![Spec](https://img.shields.io/badge/spec-SKILL.md-black?style=flat-square)](https://agentskills.io)

[English](./README.md) · [中文文档](./README.zh-CN.md)

</div>

---

这里的每个 skill 都来自一条真实跑过、摔过、修好过的工作流——里面那些约束是用真实的调试时间换来的，不是拍脑袋想的。如果某条规则听起来格外具体（比如"绝不让 Codex 跑全套测试"），那是因为它曾经真的耗掉过一个下午。

## Skills

### [`codex-implementation-loop`](./skills/codex-implementation-loop)

**类别：** 委派实现 / 编排
**适合：** 按 plan / spec / TODO 逐单元推进的工程——Codex 写代码，Claude 负责 review、测试门禁与发布。

核心分工：**Codex 写代码，Claude 掌判断。** 循环为 *拆单元 → 派发 → review → 迭代 → 测试门禁 → 发布 → 下一个*：Claude 亲自读 diff（Codex 的自我汇报是主张，不是证据）、亲自跑全套测试，只发布自己敢签名的改动。

亮点：

- **六个用户可配置的"旋钮"**，每个仓库定一次并记录：停点（`worktree`/`commit`/`pr`/`merge`）、派发模式（`implement`/`read-only`）、门禁策略（`baseline`/`strict`/`skip`）、红灯处理（`stop`/`iterate`）、review 深度（`light`/`standard`/`deep`）、节奏（`confirm`/`continuous`）
- **model / effort 默认继承用户自己的 Codex 配置**——flag 只做单次覆盖，并且 skill 知道哪些 effort 只能从 config 继承、哪些能走 flag
- **专为"委派产出的 diff"设计的 review 清单**，专猎常规 code review 会漏的东西：默认值变更导致的静默回归、被改弱以求通过的测试、永远发不出去的 gitignore 文件、悄悄加的依赖、被软化的强制边界
- **一批重新发现代价很高的环境约束**：Codex 跑在真实环境且 git 实际只读；绝不让它跑全套测试；卡死判据、取消命令、孤儿测试进程清理
- **两个实战脚本**：`codex-dispatch.sh`（自动定位最新 companion 运行时、校验参数、打印 workspace 防派错目录）和 `run-gate.sh`（如实上报套件**真实** exit code——永不被管道吞掉，并支持 flaky 套件的基线对比）

链接：[SKILL.md](./skills/codex-implementation-loop/SKILL.md) · [scripts](./skills/codex-implementation-loop/scripts)

**依赖：** [Claude Code](https://claude.com/claude-code) + 官方 OpenAI Codex 插件（提供 `codex-companion` 运行时）+ 已登录的 `codex` CLI —— 安装步骤见下。

---

## 前置 —— 装好 Codex

本 skill 通过官方 [OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc) 驱动 Codex。装一次、登录一次，之后都由 skill 接管。

在 Claude Code 里执行：

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

`/codex:setup` 会检查 `codex` CLI 是否就绪——如果没装且机器上有 npm，它会主动提出帮你装。想手动装的话：

```bash
npm install -g @openai/codex   # 需要 Node.js ≥ 18.18
codex login                    # ChatGPT 账号（含免费版）或 OpenAI API key
```

已经装过?用 CLI 自带的更新器保持最新：

```bash
codex update
```

CLI 版本旧是"新模型看起来不存在"的头号原因——并且请用 `codex update` 而不是换渠道重装：一台机器上出现两份版本错开的 `codex`，是真实发生过的坑。

> Codex 的用量计入你的 ChatGPT / API 使用额度——详见 [Codex 定价](https://developers.openai.com/codex/pricing)。

## 安装

### 方式 A —— Claude Code 插件市场

```text
/plugin marketplace add olddonkey/olddonkey-skills
/plugin install codex-implementation-loop@olddonkey-skills
```

### 方式 B —— 拷贝进个人 skills 目录

```bash
git clone https://github.com/olddonkey/olddonkey-skills /tmp/olddonkey-skills
cp -R /tmp/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/
```

### 方式 C —— 直接 clone，pull 即升级

```bash
git clone https://github.com/olddonkey/olddonkey-skills ~/Documents/olddonkey-skills
ln -s ~/Documents/olddonkey-skills/skills/codex-implementation-loop ~/.claude/skills/codex-implementation-loop
```

> 若你的 agent 不跟随 skills 目录里的软链接，请用方式 B，`git pull` 后重新拷贝一次。

## 兼容性

Skill 遵循标准 `SKILL.md` 格式（YAML frontmatter + Markdown 指令 + 附带 `scripts/`）。在 Claude Code 上构建与测试；任何读同一格式的代理理论上都能用，但附带的 shell 脚本假定 POSIX 环境（在 macOS 上开发）。

## 许可证

[MIT](./LICENSE)

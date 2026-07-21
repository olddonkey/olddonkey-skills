# Web Slides

把素材 / 提纲 / 要点做成**点击驱动的 16:9 HTML 幻灯片**，用于现场放映或
投屏 —— 电影感、留白、每屏都有动效的「动态 PPT 但不像 PPT」。

> 由 [`web-video-presentation`](https://github.com/ConardLi/garden-skills/tree/main/skills/web-video-presentation)
> （作者 ConardLi）改造而来：**去掉口播稿 / 音频合成 / 录屏**，每一步的
> 文字改成只有演讲者看得到的**演讲备注（presenter notes）**，其余视觉
> 方法论与 24 套主题系统**完全保留**。

## 这是什么

- 产出物 = 一个 Vite + React + TS 项目，点击 / 方向键推进，每一步独占整屏。
- **不是视频**：没有音频、没有录屏、没有自动播放。专做现场放映 / 投屏。
- 每章一个 `notes.ts`：数组长度 = step 数（唯一真相源），内容是演讲备注。
- 内置 24 套主题（`themes/<id>/theme.json` + `tokens.css`）+ 反 AI 味设计
  方法论（内容驱动动画、逐步揭示、电影感留白）。

## 适用场景

技术分享 / keynote / 产品演示 / pitch deck / 教学课件 / **面试项目复盘
（project retro）** / 把文章或笔记变成可交互的逐步讲解。

## 怎么用

这是一个 Claude Code / Claude.ai skill。对 agent 说类似的话即可触发：

> 「我有一些素材，帮我做成 slides」

或显式调用 `/web-slides`。完整工作流见 [`SKILL.md`](SKILL.md)。

手动起脚手架：

```bash
bash scripts/scaffold.sh ./presentation --theme=midnight-press
bash scripts/scaffold.sh --list-themes      # 看全部主题
cd presentation && npm run dev               # 默认 http://localhost:5174
```

## 放映键位

| 键 | 作用 |
|---|---|
| `←` `→` / 空格 | 上一步 / 下一步 |
| `Home` / `End` | 跳到首 / 尾 |
| `1`–`9` | 跳到第 N 章 |
| **`P`** | **开演讲者窗口**（独立窗口：口播稿 + 实时预览 + 计时器，两窗联动）—— 投屏只共享主 slide 窗口即可对观众隐藏口播稿 |
| **`N`** | 开 / 关备注浮层（叠在当前窗口上，仅排练用 —— ⚠️ 会被一起投屏） |
| 鼠标移到底部边缘 | 显出进度条（点章节 / 圆点跳转） |

## 目录

```
web-slides/
├── SKILL.md                  # 工作流 + 协作流程（agent 主入口）
├── scripts/scaffold.sh       # 一键脚手架
├── templates/                # Vite + React + TS 项目模板
├── themes/                   # 24 套主题（theme.json + tokens.css）
└── references/
    ├── OUTLINE-FORMAT.md      # outline.md 规范
    ├── CHAPTER-CRAFT.md       # 单章开发圣经（十条原则 / 决策树 / 反 AI 味）
    ├── THEMES.md             # 主题 token 契约 + 创作流程
    ├── PRESENTING.md         # 放映 / 导出
    └── EXAMPLES/             # 章节结构示意（看「形」，不抄）
```

## 致谢与许可

设计方法论、主题系统、脚手架架构来自 ConardLi 的
[garden-skills](https://github.com/ConardLi/garden-skills)（MIT License）。
本 fork 仅做「视频 → 现场 slides」的裁剪与改造，并新增独立的演讲者窗口
（presenter view，按 `P`）。

本 skill 以 [MIT License](../../LICENSE) 发布；上游 garden-skills 的
版权声明与许可见其
[LICENSE](https://github.com/ConardLi/garden-skills/blob/main/LICENSE)。

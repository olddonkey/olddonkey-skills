---
name: web-slides
description: 把素材 / 提纲 / 要点做成点击驱动的 16:9 HTML 幻灯片（slides / 演示文稿），用于现场放映或投屏 —— 不是视频，没有口播稿 / 音频合成 / 录屏。流程：原始素材 → 产出 outline 开发计划（章节切分 + 每步屏幕内容 + 可选每步演讲备注 + 信息池）→ 用户**一次对齐** 4 件事（outline / 主题 / 素材 / 开发模式）→ 网页开发（逐章 / 顺序 / 并行）。每次点击推进一个逻辑节拍，每一步独占整屏；进度条平时隐藏只在悬浮时出现；**按 P 开独立的演讲者窗口（口播稿 + 实时预览 + 计时器，与主窗口联动；投屏只共享主 slide 窗口即可对观众隐藏口播稿），按 N 是排练用的备注浮层**。内置 24 套主题 token + 反 AI 味设计方法论（内容驱动动画、逐步揭示、电影感留白）。适用场景：技术分享 / keynote / 产品演示 / pitch deck / 教学课件 / **面试项目复盘（project retro）** / 把文章或笔记变成可交互讲解。本 Skill 沉淀的是设计方法论 + 协作流程，不绑定任何特定样式 / 字体 / 颜色，可复用到任意主题与美学。
---

# Web Slides

把一堆素材 / 提纲 / 要点，一步步做成可现场放映的「电影感 HTML 幻灯片」。
产出物 = Vite + React + TS 项目，点击 / 方向键推进，每一步独占整屏，按 P
开独立的演讲者窗口看口播稿（实时预览 + 计时器，两窗联动；投屏只共享主 slide
窗口即可对观众隐藏），按 N 是排练用的备注浮层。

**与 [`web-video-presentation`] 的区别**：那个 Skill 做的是「伪装成视频的网
页」——有口播稿、合成音频、录屏成片。**本 Skill 只做现场放映的 slides**：
没有口播稿、没有音频、没有录屏；每一步的文字变成**演讲备注（presenter
notes）**，给演讲者提词用，不会出现在画面上。其余的视觉方法论、主题系统、
逐步揭示原则**完全保留**。

## 适用场景

- 「我有一些素材 / 提纲，帮我做成 slides / 演示文稿」
- 技术分享 / keynote / 产品演示 / pitch deck / 教学课件
- **面试项目复盘（project retro）** —— 现场对着 slides 讲，按 P 开演讲者窗口看提词
- 想要 16:9 横屏、大字、留白、每屏都有动效的「动态 PPT 但不像 PPT」
- 把一篇文章 / 一份笔记变成可交互的逐步讲解

本 Skill **以方法论 + 协作流程为核心**。脚手架模板提供 token 和原语，
但每个美学决策（配色、字型、动效气质）都应该针对你的主题重新设计 ——
不要照搬。

---

## 两种密度 profile：视频式 / 演示 deck 式

同一套引擎能跑两种节奏，**Phase 1 就先定一个**（写进 `outline.md` 顶部，
Checkpoint Plan 跟用户确认）：

| | 🎬 视频式（默认 / 稀疏） | 🎤 演示 deck 式（有限页 / 高密度） |
|---|---|---|
| 场景 | 录屏讲解、不停讲、节拍多 | 现场 / 投屏演讲、页数有限、围着一页讲（面试复盘常用） |
| 一张幻灯片 | = 一个 step（整屏接管） | **= 一个 chapter**（一页稳定的密集画面） |
| step 语义 | 切到下一个想法（换场景） | **同一张 slide 上逐步 build**（元素留屏渐显，不换场景） |
| 一屏信息 | 1 hero + 1~3 元素 + 大留白 | 图 / 表 / 示意 + 几条要点 + 数据可同屏 |
| 规模 | 很多章 × 少步 | 较少章（≈ 目标页数）× 每章 2~5 build |
| 主题 | 任意 | 优先结构 / 编辑型（newsroom / monochrome-print / blueprint / swiss-ikb / vintage-editorial） |

**两种都不改引擎**（chapter/step、16:9 舞台、token、MaskReveal 全通用），
差异只在**章节怎么写**。deck 式放开"一屏一想法 / 大留白 / 全 hero"，但
**「避免 AI 味」+ token + 真实层级 + 必须有视觉演示 + 双源**这套照旧 ——
那才是"不难看"的根。每章具体写法见
[`CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md)「两种密度 profile」。

> 不确定 → 🎬 视频式。

---

## 工作流总览

```
Phase 1   内容规划
   1.1  识别用户输入
   1.2  产出 outline.md
        （章节切分 + 每步屏幕内容 + 可选每步备注 + 信息池）
   ▼
[Checkpoint Plan]      ← 必须停。一次对齐 4 件事：
                         outline / 主题 / 素材 / 开发模式
   ▼
Phase 2   网页开发
   2.1  脚手架（按选定主题）
   2.2  第 1 章 = 主线程 + 完整版本（强制 anchor）
        ▼
        [硬节点] 用户验收第 1 章 ← 不可跳过
        ▼
   2.3  第 2~N 章（按选定模式：A 逐章 / B 顺序 / C 并行）
   ▼
[Checkpoint Done]     ← slides 做完，dev server 跑着
   ▼
Phase 3   放映 / 导出
```

> 没有「音频合成」和「录屏」阶段 —— 这是 slides，不是视频。

工作目录约定（agent 在用户当前目录下创建 / 编辑）：

```
my-slides/
├── material.md         # 用户给原始素材时保留 —— 不删！开发阶段画面信息源
├── outline.md          # 必有：开发计划（章节切分 + 每步内容 + 信息池 + 可选备注）
└── presentation/       # 脚手架产出的 Vite + React + TS 项目
    └── src/chapters/<NN>-<id>/
        ├── <Chapter>.tsx     # 视觉实现
        ├── <Chapter>.css
        └── notes.ts          # ★ step 数 + 演讲备注的唯一真相源
```

> **关键**：`notes.ts` 是 step 数的**唯一真相源**。章节 `.tsx` 里的
> `if (step === N)` 出现的最大 N + 1 必须等于 `notes.length`。这保证
> 章节代码、进度条、stepper 永远不会漂。备注内容（数组里的字符串）只喂
> 演讲者窗口（按 P）和备注浮层（按 N），**永远不出现在 slide 画面上**，可留空 `""`。

---

## 硬性自检协议（贯穿整个 Skill）

下面两个产出，每一个**完成后必须走自检 → 修复 → 再汇报 / 推进**：

| 产出 | 自检清单出处 |
|---|---|
| `outline.md` | [`OUTLINE-FORMAT.md`](references/OUTLINE-FORMAT.md) 自检 |
| 单章实现完成 | [`CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md) 完工自检 |

**执行方式**（按能力降级，**优先用更隔离的方式**）：

1. **Agent Teams（最优）**：开一个独立的 reviewer agent，给它「产出文件
   路径 + 对应清单 + 关键上下文」，让它逐项核查并**严格汇报结论**
   （哪几条 pass / 哪几条 fail + 证据 + 改写建议）。
2. **subAgent（次优）**：没有 Teams 能力但能开 subagent 就用 subagent
   走同样流程。
3. **自检（兜底）**：当前 agent 都没有上述能力，就自己**严格逐项**
   核查 —— 不允许目测一遍就放行。

**铁律**：拿到结论后**先按 fail 项把产出改完**，再向用户汇报「做完了
+ 自检结论 + 改了什么」。**直接拿原始结论汇报但不修复 = 违规**。

---

## 各阶段文件读取指南

不同阶段读不同的文件。**长会话里 agent 容易遗忘原则**，特别是
Phase 2.4 的「实现单章」会重复 N 次 —— 每次都要回看核心约束。

| 阶段 | 必读（每次都看） | 一次性看完 / 按需查 |
|---|---|---|
| Phase 1.1-1.2 内容规划 | `references/OUTLINE-FORMAT.md` + `material.md`（用户原始素材，如有） | —— |
| **Checkpoint Plan 选主题** | —— | `themes/*/theme.json`（动态读全部，列清单 + `bestFor` 推荐 + `descriptionZh`）；`references/THEMES.md`（用户想了解主题系统时） |
| Phase 2.1 脚手架 | —— | SKILL.md 本节看一次 |
| **Phase 2.4 实现单章（×N 次，被 2.2 / 2.3 调用）** | **`references/CHAPTER-CRAFT.md`** 单一入口 —— 视觉演示要求 / 逐步揭示 / 内容取舍 / 双源（outline+material）/ 放映审美 / 避免 AI 味 / 代码层最小约束（**含 notes.ts 强制约束**）/ 时长参考 / 完工自检 + 当前主题的 `themes/<id>/theme.json` + 当前章节的 outline.md 段落 + **`material.md` 本章对应段落** + 素材清单 | `references/EXAMPLES/`（结构示意，不是抄袭模板）；`references/THEMES.md` 完整 token 契约 |
| Phase 3 放映 / 导出 | `references/PRESENTING.md`（全屏放映、键盘导航、按 N 看备注、导出 PDF / 截图） | —— |
| 选 / 造 / 切主题 | —— | `references/THEMES.md` |

> **写章节时只读一份 `CHAPTER-CRAFT.md`**。十条原则 / 开工 self-prompting /
> 决策树 / 反 AI 味反模式 / 完工自检全部并入这一份单一入口。`EXAMPLES/`
> **不是必读** —— 先按内容自由设计，卡壳才翻（按 anchor 翻「形」，不要照搬）。

---

## Phase 1 —— 内容规划

### 1.1 识别用户输入

| 用户给的东西 | 该做的 |
|---|---|
| 原始素材（文章 / 笔记 / 一堆要点 / 数据） | 产出 `outline.md`（1.2），保留原素材为 `material.md`，过 Checkpoint Plan |
| 已经写好的提纲 / 大纲 | 整理成 `outline.md` 格式（1.2），过 Checkpoint Plan |
| 啥都没有，只说「帮我做个 X 主题的 slides」 | **反问**：先给一段素材或要点。Skill 不替用户构思内容 |

### 1.2 产出 outline.md

按 [`references/OUTLINE-FORMAT.md`](references/OUTLINE-FORMAT.md) 规则：切章节
→ 切 step → 每章首段抽**信息池** → 每步写屏幕内容（+ 可选演讲备注 hint）。

**先定密度 profile**（🎬 视频式 / 🎤 deck 式，见上方「两种密度 profile」）——
它直接决定章节怎么切：deck 式时**章节数 ≈ 目标页数**，每章 2~5 个 build。

**保留 `material.md` 不删**——它是 outline 写信息池、章节实现画面时的细节源
（双源原则）。

**outline 的边界**（关键）：

| outline 必须写 | outline 不要写 |
|---|---|
| 章节切分 / 每章 step 数 / 估时 | 具体动画类型（blur clear / wipe / 弹簧） |
| 每步屏幕内容（hero / 数据 / 标语 / 列表项） | CSS 实现手段（filter / SVG / clip-path） |
| 章节级**信息池**：从素材抽的数字 / 引用 / 案例 / 标签 | 时长 / 微观节奏数值 |
| 每步**演讲备注 hint**（可选：你打算在这一步讲什么） | 持续微动 / 错峰量等微观节奏 |
| 步级关系名前缀（「反差对照」/「递进列表」/「金句」等可选 hint） | —— |

> **outline 不写动画的理由**：写死动画 = chapter agent 退化为翻译机；
> 留白让 chapter agent 在每步开工时按 [`CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md)
> 的「内容驱动决策树」自由设计，才有真正的视觉感。

**落盘后必须先走自检再进 Checkpoint Plan**：按上文「硬性自检协议」对
`outline.md` 执行（优先 Agent Teams → subAgent → 自检），按结论修复后再进。

---

## Checkpoint Plan —— 4 件事一次对齐（**硬节点**）

`outline.md` 写完后必须停下来。**用户在这一个节点同时确认 4 件事**。

### agent 此时要做的预备工作

1. 读所有 `themes/*/theme.json` 拿 `nameZh` / `descriptionZh` / `bestFor`
   / `mood` —— **不要硬编码清单**
2. 根据 outline 的内容类型 / 关键词 / 语气，**主动**从主题里挑 2~3 套
   **最匹配的推荐**（匹配 `bestFor` 字段）
3. 扫一遍 `outline.md` 末尾「素材清单」部分

### 总结模板（骨架，agent 按情况填充）

```
内容计划写完，产出文件：
  📄 material.md    {若用户给原素材则保留}
  📄 outline.md     {N} 章 / {M} 步 + 每章信息池 + 末尾素材清单

章节速览：
  1. <id>     <章节标题>    <S> 步 ~<T>s
  2. ...

接下来一次对齐 4 件事：

  1. 开发计划 (outline.md) 要不要改？重点看：
     - 密度 profile 对不对（🎬 视频式：多步稀疏 / 🎤 deck 式：有限页高密度）
     - 章节切分 / step 数是否合理（每章 ~5~12 步是常见区间）
     - 每步屏幕内容是否清晰
     - 每章首段「信息池」是否有足够的素材细节供画面挂
     - 末尾素材清单是否完整

  2. 选哪个主题？我的推荐：
     ★ <推荐 1：nameZh (id)> — 因为 <bestFor 命中>；<descriptionZh 摘要>
     ★ <推荐 2 / 推荐 3>
     其它可选：<剩余主题，nameZh + 一句话>
     也可以让我帮你做新主题（详见 references/THEMES.md）。

  3. 真素材怎么准备？粗看本 slides 要的图：<列粗略清单>
     a) 我从 <现有素材路径> 帮你挑   b) 你自己提供   c) 全部 placeholder

  4. 开发模式选哪个？

     **第 1 章无论哪种模式都必须主线程做完 + 用户验收**（强制 anchor）。
     差异在第 2 章及之后：

     A) 默认 · 逐章确认（推荐）
        每章做完都暂停验收 → 风险可控 / 节奏最稳
     B) 第 1 章后顺序开发（不并行）
        第 2~N 章主线程顺序做完后统一验收 → 速度中 / 适合 agent 不支持并行
     C) 第 1 章后并行开发（subagent）
        第 2~N 章用 subagent 并行 → 最快 / 用户控并行数（一次几章）
        ⚠️ 风格各章会有差异（这是预期，主题禁区兜底）
```

收到反馈后：
- outline 要改：直接编辑文件，编辑完 ping 一次（或口头描述 agent 改）
- **主题必须明确**才进入 Phase 2。用户说「主题你帮我选」→ 取你推荐的第 1 个，
  **告诉用户你选了什么、为什么**，给反悔机会
- 模式选定 → 进 Phase 2

---

## Phase 2 —— 网页开发

### 2.1 脚手架

```bash
bash <path-to-web-slides>/scripts/scaffold.sh \
  ./presentation \
  --theme=<用户选的主题 id>

bash <path-to-web-slides>/scripts/scaffold.sh --list-themes
```

> 自定义主题 → 先按 [`references/THEMES.md`](references/THEMES.md)
> 「创作新主题」流程做一个 `themes/<my-theme>/`，再 `--theme=<my-theme>`。

脚手架带一个 `01-example` demo。在写第一章真实内容前**删掉**：

```bash
rm -rf presentation/src/chapters/01-example
```

并把 `presentation/src/registry/chapters.ts` 里 `example` 章节
的 import 和数组项移除。

### 2.2 第 1 章 —— 主线程 + 强制验收

**核心**：第 1 章 = 完整版本一次到位（节奏 + 视觉 + 真素材齐全）。
**没有「骨架版」概念** —— 第一章就要做出**用户能直接验收**的样板。

为什么第 1 章必须主线程：

- 它是 [`CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md) 这套指引在**当前
  主题 + 当前题材**下的第一次落地
- 如果指引有盲区 / 主题颜色 / 字体 token 不够用，第 1 章一定会暴露 ——
  这时候有人类反馈就能修指引 / 调主题，**早改成本最低**
- 后续章节（无论顺序 / 并行）都要参考第 1 章的代码模式，所以第 1 章 =
  当次项目的「风格锚点」

**做完第 1 章后必须停下来**等用户验收：

```
第 1 章 <id> 做完了，dev server 在 localhost:5174 运行。

验收重点：
  □ 视觉气质对不对？符合 <theme nameZh> 的预期吗？
  □ 节奏对不对？某些步太快 / 太慢 / 信息太薄？
  □ 内容驱动动画是否到位？还是有几步是无脑入场动画？
  □ 双源原则：屏幕画面有没有「备注没提但素材能挂」的细节？
  □ 反 AI 味检查：紫粉渐变 / 圆角彩色边框 / 假插画 / emoji 是否有？
  □ 按 N 看演讲备注，对着讲顺不顺？

问题告诉我，我针对性改。OK 了告诉我「继续」，我按选定模式做第 2 章及之后。
```

### 2.3 第 2~N 章 —— 按选定模式

**所有模式下的共同规则**：每章独立按 [`CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md)
开发。**风格不强求章节间完全一致** —— 主题颜色 / 字体 token 兜底视觉
统一，动画 / 节奏 / 视觉演示由章节自由发挥是设计预期。

#### 模式 A · 默认 · 逐章确认

第 2 章做完 → 暂停验收 → OK → 第 3 章 → 暂停 → ... → 第 N 章。**每章
独立验收**，问题随时改，**风险最低，节奏最稳**。**用户不明确选模式时
默认走这个**。

#### 模式 B · 第 1 章后顺序开发

第 2 章 → 第 3 章 → ... → 第 N 章 **主线程顺序做完，最后统一验收**。
速度中等，适合 agent 不支持并行任务的环境。

#### 模式 C · 第 1 章后并行开发（subagent）

用 subagent 把第 2~N 章并行做完，最大并行数由用户控制（「一次 4 章」
/「一次 2 章」）。**最快，但风格各章会有差异** —— 这是预期，因为：

1. 每个 subagent 看不到别的 subagent 产出，无法机械对齐
2. 章节代码物理分离（每章一个文件夹 / 自己的 CSS 前缀），不会互相破坏
3. 主题 token 兜底视觉统一（颜色 / 字体 / hero 数字 / 卡片 / 分割线
   性格 / 装饰），气质不会跑偏
4. **风格不一致 = 人手写的呼吸感**（多 voice / 多视角）

并行 subagent 的 prompt 必须包含：

- 当前章节 outline 段落（含信息池）
- `references/CHAPTER-CRAFT.md` 的路径（**单一必读**）
- 当前主题 `theme.json` 的 `descriptionZh` / `mood` / `bestFor`
- **第 1 章代码作为「代码风格」参考**（不是「视觉抄袭对象」）
- 硬规则：每章独立 CSS 前缀（`.cd-` / `.mg-` / `.pm-` / ...）；
  不修改 `chapters.ts`；**每章带 `notes.ts`**（长度 = step 数）；
  完工跑 `npx tsc --noEmit`

**重要**：无论选哪种模式，**用户随时可以中途切换模式**。

### 2.4 实现单章（每章必走）

详细指引见 [`references/CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md) ——
**单一必读入口**，覆盖：视觉演示要求 / 逐步揭示 / 内容取舍 / 双源原则
/ 视觉演示基本审美 / 反 AI 味 / 代码红线 / 完工自检。

**核心要点**（CHAPTER-CRAFT.md 详述）：

- **每章必须有 CSS / SVG / Canvas / JS 视觉演示**，禁纯文字章节
- **逐步揭示**：清单 / 列表必须 1 项 = 1 step，禁一次全展示
- **双源原则**：节奏跟 outline（顺序不能乱），细节回原始素材抽（信息池 +
  本章 material 段落）
- **每章带 `notes.ts`**：长度 = step 数（唯一真相源），内容是演讲备注
  （可留空 `""`），不会出现在画面上
- **完工自检逐项过**，不达标回去改 —— 按「硬性自检协议」执行，**改完
  再向用户汇报本章交付**

### 2.5 大改后 bump STORAGE_KEY

改动 `chapters.ts`（增加 / 删除 / 重排章节，或某章 `notes.ts` 长度变化）
后，**bump** `presentation/src/hooks/useStepper.ts` 的 `STORAGE_KEY`
（如 `web-slides-cursor-v1` → `v2`），避免持久化游标落到不存在的 step 上。

---

## Phase 3 —— 放映 / 导出

详细流程见 [`references/PRESENTING.md`](references/PRESENTING.md)。要点：

- **现场放映**：`npm run dev` → 浏览器全屏（F11）→ 点击 / 方向键推进。
- **键盘导航**：`← →` / 空格 推进；`Home` / `End` 跳首尾；数字键 `1-9`
  跳章；**按 `P` 开演讲者窗口**（独立窗口：口播稿 + 实时预览 + 计时器，两窗联动）；
  **按 `N` 开 / 关备注浮层**（叠在当前窗口上，仅排练用 —— ⚠️ 会被一起投屏）。
- **投屏看不到口播稿的正确姿势**：按 `P` 开演讲者窗口 → 会议软件里选
  「共享某个窗口 / 标签页」并选中**主 slide 窗口**（**不要**「共享整个屏幕」）→
  演讲者窗口只有你自己看得到，翻页两窗联动，单屏也成立。
- **离线分发 / 投屏稳一点**：`npm run build` → `npm run preview`，或部署
  `dist/`。
- **导出**（可选）：逐步截图成 PNG，或浏览器逐步「打印为 PDF」。

> Phase 2 结束后**主动告诉用户**：slides 做完了，dev server 跑在
> localhost:5174，可以现场放映 / 投屏；**按 P 开演讲者窗口看口播稿**（投屏时
> 只共享主 slide 窗口，观众看不到），按 N 是排练用的备注浮层（会被投屏）。

---

## 十条原则（一句话清单）

完整展开见 [`references/CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md)
的对应章节 —— **写章节时回那里查**，下面只是索引。

| # | 原则 | 一句话 |
|---|---|---|
| 1 | 16:9 固定舞台 | 内容 1920×1080 + transform scale，没有响应式 |
| 2 | 全局 step 计数器 | 章节是 step 的纯函数，无定时器 |
| 3 | 每步独占整屏 | `if (step === N) return <FullScene />` |
| 4 | **逻辑节拍 = step** | 一节拍 = 一 step = 一个聚焦想法 |
| 5 | 隐藏的边角控件 | 进度条默认 opacity 0；备注默认隐藏（按 N 开） |
| 6 | 舞台无 chrome | 没有 header / footer / 页码 / 品牌条 |
| 7 | **内容驱动动画** | 先找内在动作，找不到才入场动画兜底；持续微动慎用 |
| 8 | 多点逐个揭示 | 1 项 = 1 step，禁同步 stagger 上 N 项 |
| 9 | 整片同一主题 | 章节间不翻表面色；**颜色 / 字体走 token**，其它尺度章节自由 |
| 10 | 双源原则 | outline 定节拍，**素材定画面密度**（落到信息池） |

> 🎤 **deck 式**下原则 3「每步独占整屏」/ 8「1 项 = 1 step」放宽为：
> **一页 = 一 chapter，step = 同页逐步 build**（元素留屏渐显）；其余原则不变。
> 见上方「两种密度 profile」。

---

## 常见用户反馈速查

收到反馈先**定位是哪一层**（节奏 / 视觉 / 内容 / 代码），再改最小切片，
**不要重做整章**：

- **节奏**：太快 / 太慢 / 信息太薄 → 拆 / 合并 step（同步改 `notes.ts` 长度 + 章节 `if (step===N)`）
- **视觉**：气质不对 / 有 AI 味 → 回 CHAPTER-CRAFT.md「避免 AI 味」+「放映基本审美」
- **内容**：画面太空 / 细节不够 → 回信息池 + 本章 `material` 段落（双源原则）
- **代码**：报错 / token 不生效 → 回 CHAPTER-CRAFT.md「代码层最小约束」

---

## 相关资源

按「何时读」标注，避免一次性全读：

| 文件 | 何时读 | 内容 |
|---|---|---|
| [`references/OUTLINE-FORMAT.md`](references/OUTLINE-FORMAT.md) | Phase 1.2 必读 | outline.md 字段 spec、命名约定、章节切分、信息池、每步备注 |
| [`references/CHAPTER-CRAFT.md`](references/CHAPTER-CRAFT.md) | **Phase 2.4 每章单一必读入口** | 视觉演示要求 / 逐步揭示 / 内容取舍 / 双源（outline+material）/ 放映审美 / 避免 AI 味 / 代码层最小约束（含 notes.ts）/ 时长参考 / 完工自检 |
| [`references/EXAMPLES/`](references/EXAMPLES/) | **可选** —— 看结构 | 章节结构示意（hook / list-reveal / case-tech-review）；**不是抄袭模板** |
| [`references/THEMES.md`](references/THEMES.md) | 选 / 造 / 切主题时 | 完整 token 契约 + 内置主题清单 + 创作流程 |
| [`references/PRESENTING.md`](references/PRESENTING.md) | Phase 3 才读 | 全屏放映、键盘导航、按 N 看备注、导出 PDF / 截图 |
| [`themes/`](themes) | Checkpoint Plan / Phase 1.2 时翻 | 内置主题（每个含 `theme.json` + `tokens.css`） |
| [`scripts/scaffold.sh`](scripts/scaffold.sh) | Phase 2.1 跑一次 | 一键项目脚手架 |

---

> 本 Skill 由 [`web-video-presentation`](https://github.com/ConardLi/garden-skills/tree/main/skills/web-video-presentation)
> （作者 ConardLi）改造而来 —— 去掉口播 / 音频 / 录屏，保留全部视觉方法论
> 与主题系统，专做现场放映的 HTML slides。

# `outline.md` 格式 spec

slides 章节规划的产出文件，**直接从用户的原始素材产出**，是本 Skill
的主内容计划。**用户可以直接编辑**，所以格式必须人类友好（用 markdown
不用 JSON / YAML）。

!重要：阅读此文件后必须继续阅读 [`CHAPTER-CRAFT.md`](CHAPTER-CRAFT.md) 的全部内容，了解对网页效果的真实需求，然后再开始编写 outline

> ## ⚠️ outline 是开发计划，不是视觉规划
>
> outline 只规划**节奏 + 内容 + 信息密度**：
>
> - 章节切分 / 每章 step 数
> - 每步屏幕内容（hero / 标语 / 数据 / 列表项）
> - （可选）每步的**演讲备注提示**（讲者大概要讲什么，落到代码就是
>   该 step 的 `notes.ts` 提词）
> - 章节级**信息池**（从原始素材抽的数字 / 引用 / 案例 / 标签）
>
> **outline 里的 step 数是初始预估**。最终 step 数以章节实现时的
> `notes.ts` 为准——`notes.length` 是 step 数的唯一真相源
> （详见 [`CHAPTER-CRAFT.md`](CHAPTER-CRAFT.md) 「代码层最小约束」）。
> 如果实现时章节 step 数和 outline 不一致，回过来同步 outline 即可，
> 不需要纠结"对得严丝合缝"。

> **写 outline 前必读**（双源原则，见 [`CHAPTER-CRAFT.md`](CHAPTER-CRAFT.md)
> 「双源：节奏跟 outline，细节回原始素材」）：
>
> - **`outline.md` 自身** —— 决定**节拍**：按聚焦想法切节拍，每节拍 1~2 step
> - **原始素材**（article / 文档 / 笔记，下称 material）—— 决定**画面信息
>   密度**：每章首段抽**信息池**

---

## 抽象示例（看格式）

````markdown
# Slides Outline

> **主题**：`<theme-id>`（Checkpoint Plan 已选定）—— <一句话风格描述>
> **章节数**：<N> 章 / <M> 步

---

## 1. <chapter-id> — <章节标题>（<S> steps）

**信息池**（chapter agent 按需挂角标 / 副标 / pull-quote / mono cue）：
- <类型：数字 / 引用 / 出处 / 案例 / 词义 / 时间 / 对比 / ...>：<内容> —— <来源 material §X / Lxx>
- ...

**开发计划**：

- step 1 — <屏幕内容>
- ...

演讲备注提示（可选）：
> <讲者在这章大概要讲什么，1~3 句；落到代码就是各 step 的 notes.ts 提词>

---

## 2. <chapter-id> — ...
````

> **关于时长**：outline 里**不写**任何时长 —— 不写 step 估时、不写动画
> 时长 / 错峰量 / keyframe 数值。放映是手动推进的，视觉节奏在章节实现
> 阶段按 `mood` 决定（[`CHAPTER-CRAFT.md`](CHAPTER-CRAFT.md) 「时长参考」）。

> **想看具象示例**：
> - 钩子型开场结构 → [`EXAMPLES/hook-chapter/`](EXAMPLES/hook-chapter/)
> - 列举型章节结构 → [`EXAMPLES/list-reveal/`](EXAMPLES/list-reveal/)
> - 科技测评类（实测 / 对比 / 跑分） → [`EXAMPLES/case-tech-review/`](EXAMPLES/case-tech-review/)

---

## 字段约定

### 顶部 metadata block

用引用块（`>`）形式，方便扫一眼整体规模：

| 字段 | 必填 | 说明 |
|---|---|---|
| **主题** | ✓ | Checkpoint Plan 必须已选定。chapter agent 实现时按主题颜色 / 字体 token 走，动画 / 节奏 / 视觉演示由章节自由发挥 |
| **章节数** | ✓ | `N 章 / M 步` |

### 章节标题：`## N. <id> — <title>（<S> steps）`

| 部分 | 规则 |
|---|---|
| `N` | 1-indexed 顺序，对齐 `chapters.ts` 的注册顺序 |
| `<id>` | **小写 + 连字符**。会成为 React `key` / 文件夹名 (`src/chapters/0N-<id>/`) |
| `<title>` | 给人看的中文标题。**不会**进 React 代码 |
| `<S> steps` | 该章 step 总数 |

合法 id：`coldopen`、`hook`、`why-good`、`why-good-text-render`。
不合法：`why_good`（用连字符）、`Hook`（小写）、`第一章`（拉丁字符）。

### 章节首段「信息池」（**双源原则核心落地**）

每章独立列出从**原始素材**（material）抽的细节集合，**让 chapter agent
实现每步画面时按需取用**——可能挂成右下角 mono 角标 / 副标小字 /
pull-quote 引用 / 数据浮层。

#### 信息池条目格式

```
- <类型>：<具体内容> —— <来源 material §X / Lxx 或简注>
```

> **素材很薄（用户只给了提纲 / 几句要点）**：信息池退化为"主动设计画面
> 信息密度"——靠数字 / 对比 / 元数据等让画面信息够密。可以列"画面
> 装饰元素池"而非"素材抽取池"。

### Step 列表：每步 **1 行**

```
- step N — <屏幕内容>
```

| 规则 | 原因 |
|---|---|
| `step N` 1-indexed | agent 实现时 `if (step === N - 1) ...`（注意零基偏移） |
| **屏幕内容** | 一句话讲清楚这一步舞台上有什么：hero / 标语 / 数据 / 装饰元素。**≤ 1 行**，再多就该拆 step |
| **不写动画** | 写死 = 翻译机化（详见本文件顶部框） |
| **不写时长数值 / 错峰量** | 放映手动推进，视觉节奏在章节开发阶段决定 |
| **不写实现手段** | filter / SVG / Canvas 选型留给 chapter agent |


### 演讲备注提示（每章末尾，可选但推荐）

精炼 1~3 句，写"讲者在这章大概要讲什么"，仅供章节规划阶段对照"这章在
讲什么"。落到代码就是各 step 的 `notes.ts` 提词（讲者放映时按 `N` 看，
**不渲染到 slide**）。`outline.md` 章节边界 = 内容里两个明显主题切换
之间的段落。

---

## 命名规则速查

| 对象 | 规则 | 示例 |
|---|---|---|
| 章节 id | 小写 + 连字符 | `coldopen`, `why-good` |
| 章节文件夹 | `0N-<id>` | `src/chapters/01-coldopen/` |
| 章节组件 | PascalCase | `Coldopen.tsx`, `WhyGood.tsx` |
| 章节 CSS 类前缀 | 章节缩写（避免跨章冲突） | `.cd-` / `.wg-` / `.mg-` |
| 演讲备注文件 | 每章一个 `notes.ts` | `src/chapters/01-coldopen/notes.ts` |

---

## 章节切分的经验法则

- **每章 3~8 步**。少于 3 步太薄；多于 8 步观众会忘记这章在讲啥
- **每章 = 一个聚焦主题**。"为什么强 + 怎么用" 是两章，不是一章
- **章节边界 = 讲者会换语气 / 换主题的位置**。读一遍内容时哪里你下意识
  想"停一下、接下一段"，那里就是章节边界
- **慢节奏 / 长镜头风主题**（midnight-press / 电影感片头）每章可少到
  2~3 step；**信息密集型**（科技测评 / 对比表）每章可放宽到 8~10 step

---

## 素材清单（outline.md 末尾）

```markdown
## 素材清单

### 1. coldopen
- ✓ <资源 1 描述> （<已就位路径>）
- ⚠️ <资源 2 描述>（待提供）
- ⚠️ <资源 3 描述>（待提供）

---

## 自检（写完 outline **强制**执行，不可跳过）

> ⚠️ **硬性流程**：outline 写完后**必须**走自检 → 修改 → 提交 三步。
> **禁止**写完直接进入 Checkpoint Plan 让用户对齐。
>
> **执行方式**（按能力降级）：
>
> 1. **优先 Agent Teams**：开一个独立 reviewer agent，传入 `outline.md`
>    + 本节自检清单 + 用户原始素材（material）路径，让它**逐项核查 +
>    出结论**（哪几条 fail + 证据）。
> 2. **其次 subAgent**：当前 agent 没 Teams 但能开 subagent，用 subagent
>    走同样流程。
> 3. **都没有**：自己**严格逐项**核查。
>
> 拿到结论后**先按 fail 项改 outline，再进入 Checkpoint Plan**。

- [ ] 每个 step 都是**单一句屏幕内容描述**，没有"动画"行 / "手段"行
- [ ] 没有任何 step / 章节写了具体毫秒 / 秒数 / 时长（放映手动推进，
      不规划时长）
- [ ] 每章首段都有「信息池」block，至少 3 条素材抽取项，**每条
      必带来源标注**（`—— 来源 material §X / Lxx`）—— 没标注 chapter agent
      回不到原始素材
- [ ] 章节切分符合"每章 3~8 步 / 一个聚焦主题"经验
- [ ] 末尾「素材清单」分章节列出，✓ / ⚠️ 标注清楚
- [ ] 演讲备注提示（若写）只含人类正常可读的讲解要点，不含标题 / 序号等
      非提词内容

写完看一眼：**outline 是不是干净到 chapter agent 看了能立刻开工 + 还有
设计空间**？是 = 合格。如果你看了都觉得"太空，agent 不知道动画选什么"

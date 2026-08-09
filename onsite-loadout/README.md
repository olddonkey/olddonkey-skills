# Onsite loadout（2026-08-10 周一用）

不是一个 skill，而是按**激活方式**拆的三件东西：

| 文件 | 机制 | 为什么用这个机制 |
| --- | --- | --- |
| `rules/onsite-loadout.mdc` | Cursor project rule，`alwaysApply: true` | decision log / CUT / FREEZE 必须全天生效。skill 靠模型自主触发，当天赌不起；alwaysApply rule 保证进 context |
| `commands/demo-check.md` | Cursor command（`/demo-check`） | 一天只在 16:15 用一次，要的是确定性触发（你手动敲），不是模型判断 |
| `commands/grill.md` | Cursor command（`/grill`） | grill-me 的自有替代（见下），两个时刻用：~10:00 烤计划、~16:20 烤 demo Q&A。手动触发，零安装 |
| `NOTES.template.md` | 普通文件，开工时 cp 成 `NOTES.md` | 13:30 降档扳机、40' timebox 这类只约束**人**的规则，agent 帮不上忙，不进 agent context——写在你全天开着的文件顶部 |

裸奔路径 = 只留 `NOTES.md` 模板 + 人肉纪律。rule 和 command 是加速器，不是依赖。

## 周一安装（在给定项目 repo 里，预算 2 分钟）

```bash
mkdir -p .cursor/rules .cursor/commands
cp <clone>/onsite-loadout/rules/onsite-loadout.mdc .cursor/rules/
cp <clone>/onsite-loadout/commands/demo-check.md .cursor/commands/
cp <clone>/onsite-loadout/NOTES.template.md NOTES.md
```

`<clone>` = 周一 `git clone -b onsite` 下来的 olddonkey-skills。装完 Reload Window。

## grill-me 的处置（2026-08-09 调查后：不装，用自有 `/grill`）

调查发现（读了 mattpocock/skills 源码）：

- **`grill-me` 是一行空壳**（全文「Run a `/grilling` session」，`disable-model-invocation: true`），真身是 `skills/productivity/grilling/SKILL.md`（22 行）。上游 FAQ 原话：「I installed grill-me on its own and nothing happens」——原计划的单目录 `cp -r` 会静默失效；
- 真身只有 22 行 prompt，不是需要「安装」的软件 → 提炼成自有 `/grill` command（注明 adapted, MIT），备胎转正，每一行可辩护；
- 附带收益：`grilling` 本体是 model-invocable 的，装原版有被 agent 中途自动触发打断节奏的风险；command 形态无此问题。

**Plan B（如果当天仍想用原版）**，两个目录都要装，且 Cursor 对 skills 的支持未验证：

```bash
git clone --depth 1 https://github.com/mattpocock/skills.git /tmp/mp-skills
mkdir -p ~/.cursor/skills
cp -r /tmp/mp-skills/skills/productivity/grilling ~/.cursor/skills/
cp -r /tmp/mp-skills/skills/productivity/grill-me ~/.cursor/skills/  # 可选：仅是显式触发的前门
```

## 周六 mock 必测五项（每项不过就按 keep-or-drop 处理）

1. **rule 是否真的加载**：装完问 agent「今天关于 NOTES.md 你要遵守什么规则」，答不上 = 没生效 → 查 `.mdc` 是否被识别（Cursor 设置里 Rules 面板应能看到）。
2. **decision log 自动落行**：上午干活，数 agent 主动 `echo >> NOTES.md` 的次数。12:00 前为 0 → rule 不管用 → 裸奔（人肉记）。
3. **FREEZE 是否守得住**：喊 FREEZE 后故意要一个小 feature，agent 必须拒绝并把它记到 If I had another day。
4. **/demo-check 真跑**：16:15 敲 `/demo-check`，必须真的跑 git status / 测试 / demo 干跑并输出状态表。如果 Cursor 版本不支持 commands → 退化为 `@demo-check.md 照着执行`，零损失。
5. **/grill 两个时刻各烤一轮**：计划初稿后一次、freeze 后一次。验收：问题按 ❓ 编号成轮、每问带 ➡️ 推荐答案、能按编号作答、喊 WRAP 立刻收束并输出三段式 summary（缺口 / 扩展候选 / decision log 行）。纪律照旧：一行答案记下就走，10–15 分钟封顶。

## 设计取舍（现场被问到也能答）

- **agent 用 `echo >> NOTES.md` 追加而不是编辑文件**：append-only 由 shell 保证，agent 不可能改坏你的 log；`$(date +%H:%M)` 顺便解决 agent 不知道时间的问题。
- **REJECTED 行只许人写**：「否掉 agent 产出」是 rubric 计数项，也是你 demo 时最值钱的辩护证据，必须出自你手。
- **`git tag core-done`**：把 B+ 状态钉死，扩展怎么砍 demo 都有退路——这就是「半成品扩展比没有扩展更糟」的机械化保险。

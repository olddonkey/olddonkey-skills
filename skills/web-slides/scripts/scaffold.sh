#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# scaffold.sh —— 一键脚手架，创建一个 web-slides 项目（HTML 幻灯片）。
#
# 用法：
#   bash scripts/scaffold.sh <target-dir> [--theme=<id>]
#   bash scripts/scaffold.sh --list-themes
#
# 例子：
#   bash <path-to-web-slides>/scripts/scaffold.sh ./presentation
#   bash <path-to-web-slides>/scripts/scaffold.sh ./talk --theme=paper-press
#   bash <path-to-web-slides>/scripts/scaffold.sh --list-themes
#
# 跑完后，看 SKILL.md "Phase 2.4 实现单章" + references/CHAPTER-CRAFT.md
# 了解每章怎么写。卡壳时翻 references/EXAMPLES/ 找完整章节 anchor。
#
# 之后切换主题，覆盖一个文件即可：
#   cp <path-to-web-slides>/themes/<id>/tokens.css \
#      <project>/src/styles/tokens.css
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="$SKILL_DIR/templates"
THEMES_DIR="$SKILL_DIR/themes"
DEFAULT_THEME="midnight-press"

list_themes() {
  echo "可用主题（来自 ${THEMES_DIR}）:"
  echo
  for dir in "$THEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local meta="$dir/theme.json"
    [[ -f "$meta" ]] || continue
    # 没有 jq，简单 grep + sed 提字段
    local id name desc
    id=$(grep -E '"id"' "$meta" | head -n1 | sed -E 's/.*"id":[[:space:]]*"([^"]+)".*/\1/')
    name=$(grep -E '"nameZh"' "$meta" | head -n1 | sed -E 's/.*"nameZh":[[:space:]]*"([^"]+)".*/\1/')
    desc=$(grep -E '"descriptionZh"' "$meta" | head -n1 | sed -E 's/.*"descriptionZh":[[:space:]]*"([^"]+)".*/\1/')
    printf "  • %-18s %s\n      %s\n\n" "$id" "$name" "$desc"
  done
  echo "用 --theme=<id> 选定一个。默认：${DEFAULT_THEME}。"
}

# ── 解析参数 ──
TARGET=""
THEME="$DEFAULT_THEME"
for arg in "$@"; do
  case "$arg" in
    --list-themes)
      list_themes
      exit 0
      ;;
    --theme=*)
      THEME="${arg#--theme=}"
      ;;
    --*)
      echo "✗ 未知参数: $arg" >&2
      exit 1
      ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$arg"; fi
      ;;
  esac
done

TARGET="${TARGET:-presentation}"
THEME_DIR="$THEMES_DIR/$THEME"
THEME_TOKENS="$THEME_DIR/tokens.css"

if [[ ! -d "$THEME_DIR" || ! -f "$THEME_TOKENS" ]]; then
  echo "✗ 找不到主题 '${THEME}'。可用主题：" >&2
  echo >&2
  for dir in "$THEMES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    echo "    • $(basename "$dir")" >&2
  done
  exit 1
fi

if [[ -d "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null || true)" ]]; then
  echo "✗ 目标目录 '${TARGET}' 已存在且非空，已中止。" >&2
  exit 1
fi

if ! command -v npm >/dev/null; then
  echo "✗ 需要 npm，但在 PATH 里没找到。" >&2
  exit 1
fi

echo "▸ 在 $TARGET 创建 Vite + React + TS 项目"
echo "▸ 使用主题：$THEME"
npm create vite@latest "$TARGET" -- --template react-ts >/dev/null

cd "$TARGET"
echo "▸ 安装依赖（可能要等一会）..."
npm install >/dev/null 2>&1

echo "▸ 用演示骨架替换默认 boilerplate"

# 干掉我们不要的 Vite 默认 boilerplate
rm -f \
  src/App.tsx src/App.css \
  src/main.tsx src/index.css \
  README.md
# 默认模板自带的 demo 资源（名字随 vite 版本变化），整目录清掉更稳
rm -rf src/assets
rm -f public/*.svg

# 把脚手架文件拷到项目根
mkdir -p \
  src/styles src/hooks src/components src/registry \
  src/chapters/01-example \
  public

cp "$TEMPLATES/vite.config.ts" .
cp "$TEMPLATES/index.html" .

cp "$TEMPLATES/src/main.tsx" src/main.tsx
cp "$TEMPLATES/src/App.tsx"  src/App.tsx
cp "$TEMPLATES/src/PresenterApp.tsx" src/PresenterApp.tsx

# tokens.css 来自所选主题
cp "$THEME_TOKENS"                          src/styles/tokens.css
cp "$TEMPLATES/src/styles/base.css"         src/styles/base.css
cp "$TEMPLATES/src/styles/animations.css"   src/styles/animations.css
cp "$TEMPLATES/src/styles/fonts.css"        src/styles/fonts.css

cp "$TEMPLATES/src/hooks/useStageScale.ts"      src/hooks/useStageScale.ts
cp "$TEMPLATES/src/hooks/useStepper.ts"         src/hooks/useStepper.ts
cp "$TEMPLATES/src/hooks/usePresenterNotes.ts"  src/hooks/usePresenterNotes.ts
cp "$TEMPLATES/src/hooks/useFitScale.ts"        src/hooks/useFitScale.ts

cp "$TEMPLATES/src/components/Stage.tsx"          src/components/Stage.tsx
cp "$TEMPLATES/src/components/MaskReveal.tsx"     src/components/MaskReveal.tsx
cp "$TEMPLATES/src/components/ProgressBar.tsx"    src/components/ProgressBar.tsx
cp "$TEMPLATES/src/components/ProgressBar.css"    src/components/ProgressBar.css
cp "$TEMPLATES/src/components/NotesOverlay.tsx"   src/components/NotesOverlay.tsx
cp "$TEMPLATES/src/components/NotesOverlay.css"   src/components/NotesOverlay.css
cp "$TEMPLATES/src/components/SlidePreview.tsx"   src/components/SlidePreview.tsx
cp "$TEMPLATES/src/components/PresenterView.tsx"  src/components/PresenterView.tsx
cp "$TEMPLATES/src/components/PresenterView.css"  src/components/PresenterView.css

cp "$TEMPLATES/src/registry/types.ts"    src/registry/types.ts
cp "$TEMPLATES/src/registry/chapters.ts" src/registry/chapters.ts

cp "$TEMPLATES/src/chapters/01-example/Example.tsx"     src/chapters/01-example/Example.tsx
cp "$TEMPLATES/src/chapters/01-example/Example.css"     src/chapters/01-example/Example.css
cp "$TEMPLATES/src/chapters/01-example/notes.ts"        src/chapters/01-example/notes.ts

# 留个标记，以后能查这个项目从哪个主题起步的
{
  echo "$THEME"
} > .theme

# 跑一次 typecheck 确认接线 OK
echo "▸ 跑 typecheck ..."
if npx tsc --noEmit; then
  echo "✓ typecheck 通过"
else
  echo "✗ typecheck 失败 —— 请看上面的错误" >&2
  exit 1
fi

cat <<EOF

✓ 完成。下一步：

  1. cd $TARGET
  2. npm run dev      # 起本地服务，终端会打印实际地址（默认 http://localhost:5174）

当前主题：${THEME}（见 .theme）

然后：

  • 点舞台任意位置（或按 → / 空格）推进全局 step 计数器。
  • 鼠标移到底部边缘可显出进度条（点章节 / 圆点可跳转）。
  • **按 N 开 / 关备注浮层** —— 浮在 *当前这一个窗口* 上，适合一个人对屏排练。
    ⚠️ 它和 slide 在同一个窗口里，所以投屏时会被一起 share 出去。
  • **按 P 开「演讲者窗口」（presenter view）** —— 一个独立窗口：当前页实时预览
    + 口播稿 + 下一页 + 计时器 + 页码，和主窗口自动联动翻页。开会时
    **只共享主 slide 窗口 / 标签页（不要共享整个屏幕）**，演讲者窗口就只有你看得到。
    这才是「观众看不到口播稿」的正确做法，单屏也成立。详见 references/PRESENTING.md。
  • 把 src/chapters/01-example/ 替换成你自己的章节
    （流程见 SKILL.md "Phase 2.4 实现单章" —— 每章一次到位完整版本，
     不分骨架 / 精修两步；动画选型由 chapter agent 按 CHAPTER-CRAFT.md
     的内容驱动原则即时决定）。
  • 在 src/registry/chapters.ts 注册每个新章节。
  • **每章必须有 notes.ts**（与 Example.tsx 同目录），数组长度 = step 数，
    是 step 数的唯一真相源；内容是演讲备注（可留空 ""）—— 它喂的是演讲者窗口
    （按 P）和备注浮层（按 N），不会出现在 slide 上。
  • 章节改了就 bump src/hooks/useStepper.ts 的 STORAGE_KEY 末尾版本号。

放映 / 分享：

  • 现场放映：npm run dev → 主窗口浏览器全屏（F11）→ 点击 / 方向键推进。
    键盘：← → / 空格 推进，Home/End 跳首尾，数字键 1-9 跳章，N 备注浮层，P 演讲者窗口。
  • **会议投屏（看不到口播稿的正确姿势）**：按 P 开演讲者窗口 → 在 Meet/Zoom/GVC
    里选「共享某个窗口 / 标签页」并选中 **主 slide 窗口**（不要「共享整个屏幕」）→
    两个窗口翻页自动联动，演讲者窗口只有你自己看得到。单屏也成立。
  • 离线分发：npm run build → npm run preview（或部署 dist/）。
  • 导出：逐步截图成 PNG，或浏览器逐步「打印为 PDF」。详见 references/PRESENTING.md。

写章节时必读（单一入口，路径在 SKILL 仓库内）：

  • $SKILL_DIR/references/CHAPTER-CRAFT.md
      视觉演示要求 / 逐步揭示 / 内容取舍 / 双源(outline+material) /
      放映审美 / 避免 AI 味 / 代码层约束(含 notes.ts) /
      时长参考 / 完工自检
  • $SKILL_DIR/themes/$THEME/theme.json
      看 descriptionZh / mood / bestFor —— 参考主题气质
      （动画 / 时长 / 字号 / emoji 由 chapter agent 在每章自由决定）

卡壳时可翻：

  • $SKILL_DIR/references/EXAMPLES/
      完整章节 anchor（钩子型 / 列举型）—— 看"形"，不要照搬

要换一个主题，覆盖 tokens.css 即可：
  cp $SKILL_DIR/themes/<id>/tokens.css src/styles/tokens.css

想自创主题，看 $SKILL_DIR/references/THEMES.md。

EOF

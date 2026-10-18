#!/usr/bin/env bash
# 给已安装的 dsh-bili-scroll 打 volatile 解引用修复。
#
#   ./apply-fix.sh                # 打补丁（默认 profile = desktop）
#   ./apply-fix.sh web            # 指定 profile
#   ./apply-fix.sh --revert       # 还原
#
# 幂等：已经打过就跳过。打之前自动备份成 index.js.bak-volatile-<时间戳>。

set -euo pipefail

PROFILE="desktop"
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    *) PROFILE="$arg" ;;
  esac
done

PLUGIN="$HOME/.dsh/profiles/$PROFILE/node_modules/dsh-bili-scroll"
INDEX="$PLUGIN/index.js"

[ -f "$INDEX" ] || { echo "找不到 ${INDEX} —— profile「${PROFILE}」没装这个插件？" >&2; exit 1; }

# ── 还原 ──
if [ "$REVERT" = "1" ]; then
  BAK=$(ls -t "$PLUGIN"/index.js.bak-volatile-* 2>/dev/null | head -1)
  [ -n "$BAK" ] || { echo "没有可还原的备份" >&2; exit 1; }
  cp "$BAK" "$INDEX"
  echo "已还原：$INDEX ← $(basename "$BAK")"
  node --check "$INDEX" && echo "语法检查通过"
  exit 0
fi

# ── 幂等检查 ──
if grep -q "typeof v.get === 'function'" "$INDEX"; then
  echo "已经打过补丁了，跳过。"
  exit 0
fi

# ── 定位目标行 ──
# normalize() 里的 `const v = src?.[k]`。用 awk 找 "const normalize" 之后第一处，避免误伤别处。
LINE=$(awk '/const normalize = \(src, base\)/{f=1} f && /const v = src\?\.\[k\]/{print NR; exit}' "$INDEX")
[ -n "$LINE" ] || { echo "没找到 normalize() 里的 \`const v = src?.[k]\` —— 插件版本可能变了，别硬打。" >&2; exit 1; }

echo "目标行：$INDEX:$LINE"
sed -n "$((LINE-1)),$((LINE+1))p" "$INDEX" | sed 's/^/  /'

# ── 备份 ──
BAK="$PLUGIN/index.js.bak-volatile-$(date +%s)"
cp "$INDEX" "$BAK"
echo "已备份 → $(basename "$BAK")"

# ── 打补丁：把那一行换成 4 行 ──
python3 - "$INDEX" "$LINE" <<'PY'
import sys
path, line_no = sys.argv[1], int(sys.argv[2])
lines = open(path, encoding='utf-8').read().split('\n')
i = line_no - 1

indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
new = [
    f"{indent}// ⭐ volatile 字段在 config 里是**引用对象**（{{ get() }}），不是标量 —— 不解引用就等于全被丢弃、",
    f"{indent}//    一律回落默认值 ⇒ 设置页里改的每个键都静默失效（pythonPath 永远 'python' 就是这条）。",
    f"{indent}let v = src?.[k]",
    f"{indent}if (v && typeof v === 'object' && typeof v.get === 'function') {{ try {{ v = v.get() }} catch {{ /* 拿不到就当没设 */ }} }}",
]
lines[i:i+1] = new
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
PY

# ── 验证 ──
node --check "$INDEX" || { echo "语法检查失败，正在还原"; cp "$BAK" "$INDEX"; exit 1; }
# 加载测试只在插件目录完整时做（缺 lib/ 的副本会误报 Cannot find module）
if [ -d "$PLUGIN/lib" ]; then
  node --input-type=module -e "import('$INDEX').then(m => console.log('加载 OK:', m.name, m.inject)).catch(e => { console.error('加载失败:', e.message); process.exit(1) })" \
    || { echo "加载失败，正在还原"; cp "$BAK" "$INDEX"; exit 1; }
else
  echo "（没有 lib/ 目录，跳过加载测试）"
fi

echo
echo "✅ 打好了。重启 DSH 后生效："
echo "   osascript -e 'quit app id \"com.deepseek.dsh\"' && open -b com.deepseek.dsh"
echo
echo "还原：$0 --revert"

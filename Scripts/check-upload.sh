#!/bin/bash
# check-upload.sh — 排查「哪些文件不应该上传到 GitHub」
#
# 用法:  ./Scripts/check-upload.sh
# 退出码: 0 = 干净（或仅有警告）  1 = 发现必须处理的问题
#
# 检查内容:
#   [1] 实际会被上传的文件清单及总体积（git 已跟踪 + 未跟踪且未被忽略）
#   [2] 构建产物 / 临时文件是否存在且未被 .gitignore 覆盖
#   [3] 大文件（>1MB 警告，>5MB 必须处理）
#   [4] 可疑的二进制文件（非常见资源格式）
#   [5] 疑似密钥/口令（api key、password、token、私钥等）
#   [6] 未跟踪且未被忽略的文件（git add -A 时会误上传）
set -u
cd "$(dirname "$0")/.." || exit 1

errors=0
warnings=0
err()  { printf '  [X] %s\n' "$*"; errors=$((errors + 1)); }
warn() { printf '  [!] %s\n' "$*"; warnings=$((warnings + 1)); }
info() { printf '  - %s\n' "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }

human() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (b == int(b) ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "当前目录不是 git 仓库"; exit 1
fi

echo "==== NotesMD 上传排查 ===="
echo "仓库根: $(pwd)"

# ---- 会被上传的文件 ----
upcoming=$( { git ls-files; git ls-files --others --exclude-standard; } | sort -u )

echo
echo "[1] 会被上传的文件（已跟踪 + 未跟踪且未被忽略）:"
count=0
total=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  sz=$(wc -c < "$f" | tr -d ' ')
  total=$((total + sz))
  count=$((count + 1))
  printf '  %10s  %s\n' "$(human "$sz")" "$f"
done <<< "$upcoming"
info "共 $count 个文件，合计 $(human "$total")"

# ---- 构建产物 / 临时文件 ----
echo
echo "[2] 构建产物与临时文件（应被 .gitignore 覆盖）:"
ARTIFACT_PATTERNS=".build .swiftpm xcuserdata DerivedData .env .idea .vscode *.log *.o *.app .DS_Store"
hit_all=0
for pat in $ARTIFACT_PATTERNS; do
  hits=$(find . -name "$pat" -not -path "./.git/*" 2>/dev/null | head -15)
  [ -n "$hits" ] || continue
  while IFS= read -r p; do
    hit_all=1
    if git check-ignore -q -- "$p"; then
      ok "已忽略: $p"
    else
      err "未被忽略: $p  （请加入 .gitignore）"
    fi
  done <<< "$hits"
done
# 顶层 build/ 目录单独检查（find -name build 可能漏掉）
if [ -d "build" ]; then
  hit_all=1
  if git check-ignore -q -- "build"; then
    ok "已忽略: build/"
  else
    err "未被忽略: build/  （请加入 .gitignore）"
  fi
fi
[ "$hit_all" = 1 ] || ok "未发现构建产物/临时文件"

# ---- 大文件 ----
echo
echo "[3] 大文件检查（>1MB 警告，>5MB 必须处理）:"
big_found=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  sz=$(wc -c < "$f" | tr -d ' ')
  if [ "$sz" -gt 5242880 ]; then
    err "$(human "$sz")  $f  （超过 5MB，GitHub 会警告/拒绝，建议 LFS 或移除）"
    big_found=1
  elif [ "$sz" -gt 1048576 ]; then
    warn "$(human "$sz")  $f"
    big_found=1
  fi
done <<< "$upcoming"
[ "$big_found" = 1 ] || ok "无大文件"

# ---- 可疑二进制文件 ----
echo
echo "[4] 二进制文件检查（非常见资源格式会警告）:"
bin_found=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.icns|*.png|*.jpg|*.jpeg|*.webp|*.gif|*.pdf) continue ;;
  esac
  kind=$(file -b "$f" 2>/dev/null)
  case "$kind" in
    ASCII*|UTF-8*|Unicode*|text*|empty*|*script*|*source*) continue ;;
  esac
  warn "二进制文件: $f  （$kind）— 确认是否为需要上传的资源"
  bin_found=1
done <<< "$upcoming"
[ "$bin_found" = 1 ] || ok "无可疑二进制文件"

# ---- 疑似密钥 ----
echo
echo "[5] 疑似密钥/口令扫描:"
sec_found=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  sz=$(wc -c < "$f" | tr -d ' ')
  [ "$sz" -gt 524288 ] && continue
  kind=$(file -b "$f" 2>/dev/null)
  case "$kind" in ASCII*|UTF-8*|Unicode*|text*|empty*|*script*|*source*) ;; *) continue ;; esac
  hits=$(grep -inE 'api[_-]?key|secret|password|passwd|access[_-]?token|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY' -- "$f" | head -3)
  if [ -n "$hits" ]; then
    warn "$f:"
    printf '%s\n' "$hits" | sed 's/^/      /'
    sec_found=1
  fi
done <<< "$upcoming"
[ "$sec_found" = 1 ] || ok "未发现疑似密钥"

# ---- 未跟踪且未被忽略 ----
echo
echo "[6] 未跟踪且未被忽略的文件（git add -A 会一并上传，请确认）:"
others=$(git ls-files --others --exclude-standard)
if [ -n "$others" ]; then
  printf '%s\n' "$others" | while IFS= read -r f; do
    warn "未跟踪: $f"
  done
else
  ok "无未跟踪文件"
fi

# ---- 汇总 ----
echo
echo "==== 汇总: 必须处理 $errors 项, 警告 $warnings 项 ===="
[ "$errors" -gt 0 ] && exit 1
exit 0

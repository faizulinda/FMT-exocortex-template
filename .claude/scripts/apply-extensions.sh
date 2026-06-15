#!/bin/bash
# apply-extensions.sh — применяет пользовательские расширения скиллов в рантайм.
#
# Закрывает пробел: Extensions Gate (extensions-gate.sh) требует писать кастомные
# скиллы в extensions/skills/, но ничто не применяло их в .claude/skills/.
# Этот скрипт копирует extensions/skills/<name>/* → .claude/skills/<name>/*.
# Идемпотентен (копирует только изменённые файлы). Вешается на SessionStart.

set -e
WS="$(cd "$(dirname "$0")/../.." && pwd)"   # .claude/scripts → IWE
EXT="$WS/extensions/skills"
DST="$WS/.claude/skills"

[ -d "$EXT" ] || exit 0

applied=0
for d in "$EXT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  mkdir -p "$DST/$name"
  for f in "$d"*; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"
    if ! cmp -s "$f" "$DST/$name/$bn" 2>/dev/null; then
      cp "$f" "$DST/$name/$bn"
      applied=$((applied + 1))
    fi
  done
done

[ "$applied" -gt 0 ] && echo "[apply-extensions] применено в .claude/skills: $applied файл(ов)" >&2
exit 0

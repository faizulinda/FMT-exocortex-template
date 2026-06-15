#!/bin/bash
# Extensions Gate Hook
# Event: PreToolUse (matcher: Edit, Write)
# Блокирует прямое редактирование .claude/skills/ и memory/protocol-*.md
#
# Исключения:
#   - FMT-exocortex-template (шаблон — всегда разрешён)
#   - author_mode: true в params.yaml (автор шаблона — source-of-truth в IWE,
#     пропагация в FMT через template-sync.sh)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Проверяем: это L1 файл?
if echo "$FILE_PATH" | grep -qE '\.claude/skills/|memory/protocol-'; then

  # Исключение 1: FMT-exocortex-template — всегда разрешён
  if echo "$FILE_PATH" | grep -q 'FMT-exocortex-template'; then
    exit 0
  fi

  # Исключение 2: author_mode в params.yaml
  WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ -f "$WORKSPACE_DIR/params.yaml" ] && grep -qE '^author_mode:\s*true' "$WORKSPACE_DIR/params.yaml" 2>/dev/null; then
    exit 0
  fi

  # Блокировать для обычных пользователей
  echo '{"decision": "block", "reason": "⛔ Extensions Gate: L1 (платформа) и L3 (пользователь) — разные слои. Кастомизацию скилла пиши в extensions/skills/<name>/SKILL.md — она применяется в .claude/skills/ на старте сессии (apply-extensions.sh) либо вручную: bash .claude/scripts/apply-extensions.sh. Платформенное изменение → FMT-exocortex-template → update.sh."}'
  exit 0
fi

# Разрешить редактирование обычных файлов
echo '{}'
exit 0

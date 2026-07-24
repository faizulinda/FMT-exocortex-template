#!/usr/bin/env bash
# routing: helper  called-by=wp-gate  deterministic=true
# see DP.SC.159, DP.ROLE.059
# create-wp.sh — атомарное создание РП в 4 местах (inbox, REGISTRY, WeekPlan, Linear)
# see WP-297 Ф6.2 (${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-297-wp-lifecycle-architecture.md)
# see DP.M.010, DP.ROLE.037
#
# Использование:
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 [--slug slug] [--repo "репо"] [--zone Work|Self|Side] [--deadline "дата"] [--related "WP-150:dependency,WP-167:продукт"]
#   bash create-wp.sh --title "Название" --budget 5h --priority P3 --no-consent-check
#
# Предусловие: consent state file должен существовать:
#   touch ${IWE:-$HOME/IWE}/.claude/state/wp-consent-{N}
#
# Схема REGISTRY: скрипт сам определяет набор колонок по заголовку таблицы
# (обязательны только "#" и "Название"; остальные — P/Ст/Репо/Зона/Источник/
# Бюджет/Дедлайн/Активация — заполняются, если колонка присутствует, иначе
# пропускаются). см. bug-2026-07-24-create-wp-registry-schema-drift.md.
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
INBOX="$STRATEGY/inbox"
STATE_DIR="$IWE/.claude/state"

# --- Параметры ---
TITLE=""
BUDGET=""
PRIORITY="P3"
SLUG=""
REPO=""
ZONE=""
DEADLINE=""
RELATED=""
RESULT=""
SKIP_CONSENT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2";    shift 2 ;;
    --budget)   BUDGET="$2";   shift 2 ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --slug)     SLUG="$2";     shift 2 ;;
    --repo)     REPO="$2";     shift 2 ;;
    --zone)     ZONE="$2";     shift 2 ;;
    --deadline) DEADLINE="$2"; shift 2 ;;
    --related)  RELATED="$2";  shift 2 ;;
    --result)   RESULT="$2";   shift 2 ;;
    --no-consent-check) SKIP_CONSENT=1; shift ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

# --- Валидация ---
if [[ -z "$TITLE" || -z "$BUDGET" ]]; then
  echo "Использование: $0 --title \"Название\" --budget 5h [--priority P3] [--slug slug] [--repo репо] [--zone Work|Self|Side] [--deadline дата] [--related \"WP-NNN:тип\"] [--result R3]" >&2
  exit 1
fi

# --- Найти следующий номер WP ---
WP_NUM=$(python3 - "$REGISTRY" <<'PYEOF' 2>/dev/null
import sys, re
registry = sys.argv[1]
max_num = 0
try:
    with open(registry, "r", encoding="utf-8") as f:
        for line in f:
            # Ищем строки вида | 297 |, | ~~297~~ | или legacy-формат | WP-297 |
            m = re.match(r"^\|\s*[*~]*(?:WP-)?(\d+)[*~]*\s*\|", line)
            if m:
                n = int(m.group(1))
                if n > max_num:
                    max_num = n
except Exception as e:
    print(0, file=sys.stderr)
print(max_num + 1)
PYEOF
)

if [[ -z "$WP_NUM" || "$WP_NUM" -le 0 ]]; then
  echo "❌ Не удалось определить следующий номер WP из REGISTRY" >&2
  exit 1
fi

# --- Защита от повторной выдачи номера (issue: create-wp-registry-schema-drift) ---
# Если предыдущий запуск упал ПОСЛЕ создания inbox/WP-{N}/ но ДО записи в REGISTRY
# (например, схема REGISTRY не совпала), повторный запуск иначе вычислил бы тот же
# WP_NUM из REGISTRY (который не обновился) и молча перезаписал бы уже созданный
# context file содержимым новой задачи. Резервируем номер по факту существования
# папки, не только по REGISTRY.
INBOX_MAX_NUM=0
if [[ -d "$INBOX" ]]; then
  for d in "$INBOX"/WP-*; do
    [[ -d "$d" ]] || continue
    n="${d##*/WP-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > INBOX_MAX_NUM )) && INBOX_MAX_NUM=$n
  done
fi
if (( INBOX_MAX_NUM >= WP_NUM )); then
  OLD_WP_NUM=$WP_NUM
  WP_NUM=$(( INBOX_MAX_NUM + 1 ))
  echo "ℹ️  Номер скорректирован: $OLD_WP_NUM → $WP_NUM (папка inbox/WP-${INBOX_MAX_NUM}/ уже существует — вероятно, от прерванного предыдущего запуска)" >&2
fi

echo "📋 Следующий номер WP: $WP_NUM"

# --- Проверка consent ---
CONSENT_FILE="$STATE_DIR/wp-consent-${WP_NUM}"
if [[ "$SKIP_CONSENT" -eq 0 ]]; then
  if [[ ! -f "$CONSENT_FILE" ]]; then
    echo "🚫 WP Gate: нет согласия пользователя на создание WP-${WP_NUM}" >&2
    echo "   Создайте consent file и повторите:" >&2
    echo "   touch $CONSENT_FILE" >&2
    exit 1
  fi
  echo "✅ Consent: $CONSENT_FILE"
fi

# --- Дата ---
TODAY=$(date +%Y-%m-%d)

# --- Slug из title (если не задан) ---
if [[ -z "$SLUG" ]]; then
  SLUG=$(echo "$TITLE" | python3 -c "
import sys, re, unicodedata
s = sys.stdin.read().strip().lower()
# Транслитерация кириллицы
tr = {
  'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh',
  'з':'z','и':'i','й':'j','к':'k','л':'l','м':'m','н':'n','о':'o',
  'п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts',
  'ч':'ch','ш':'sh','щ':'shch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'
}
result = ''
for c in s:
    result += tr.get(c, c)
result = re.sub(r'[^a-z0-9]+', '-', result)
result = result.strip('-')[:40]
print(result)
" 2>/dev/null || echo "wp-$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-30)")
fi

# Inbox convention (WP-434): every WP is a folder inbox/WP-N/ with main file WP-N.md.
# Slug is dropped from the filename (lives in title: frontmatter).
WP_DIR="$INBOX/WP-${WP_NUM}"
WP_FILE="$WP_DIR/WP-${WP_NUM}.md"
mkdir -p "$WP_DIR"

echo "🚀 Создаю WP-${WP_NUM}: $TITLE"
echo "   Папка: inbox/WP-${WP_NUM}/WP-${WP_NUM}.md"
echo "   Бюджет: $BUDGET | Приоритет: $PRIORITY"

# --- Сформировать строки таблицы связок ---
RELATED_ROWS="| — | — | — | нет связок |"
if [[ -n "$RELATED" ]]; then
  RELATED_ROWS=""
  IFS=',' read -ra REL_ITEMS <<< "$RELATED"
  for rel_item in "${REL_ITEMS[@]}"; do
    rel_item="${rel_item# }"
    rel_wp="${rel_item%%:*}"
    rel_type="${rel_item#*:}"
    [[ "$rel_wp" == "$rel_type" ]] && rel_type="—"
    RELATED_ROWS+="| ${rel_wp} | 🟡 | ${rel_type} | — |
"
  done
fi

# --- Шаг 1: context file ---
echo ""
echo "1/5 context file..."

cat > "$WP_FILE" <<WPEOF
---
wp: ${WP_NUM}
title: "${TITLE}"
status: pending
priority: ${PRIORITY}
budget: ${BUDGET}
created: ${TODAY}
last_session: ${TODAY}
related: []
activation: on-demand
---

# WP-${WP_NUM}: ${TITLE}

## Проблема

[Описать неудовлетворённость / проблему, которую решает этот РП]

## Артефакт

[Конкретный результат — существительное-артефакт с критериями]

## Связки с РП

| РП | Сила | Тип | Что передаётся |
|----|------|-----|----------------|
${RELATED_ROWS}

## Фазы реализации

### Ф1 — [Название фазы] (~?h)

- [ ] ...

## Что узнали

[Заполняется при сессиях]

## Осталось

**Что пробовали:** не начат
**Что узнали:** —
  → memory: не нужно
**Что дальше:**
- [ ] Открыть сессию, прочитать задачу, составить план
**Следующий шаг:** Открыть сессию — прочитать задачу, составить план
**Контекст для следующей сессии:** РП только создан, нет контекста
WPEOF

echo "   ✅ $WP_FILE"

# --- Шаг 2: WP-REGISTRY.md ---
echo "2/5 WP-REGISTRY.md..."

if ! python3 - "$REGISTRY" "$WP_NUM" "$PRIORITY" "$TITLE" "$REPO" "$BUDGET" "$GOV_REPO" "$ZONE" "$RESULT" "$DEADLINE" <<'PYEOF'
import sys
registry_path, wp_num, priority, title, repo, budget, gov_repo, zone, result, deadline = sys.argv[1:11]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Найти строку-разделитель после заголовка таблицы (|---|---|...)
insert_at = None
header_line = None
for i, line in enumerate(lines):
    if line.strip().startswith("|---") and i > 0 and lines[i-1].strip().startswith("| #"):
        insert_at = i + 1
        header_line = lines[i-1]
        break

if insert_at is None:
    print("❌ Не найден заголовок таблицы REGISTRY", file=sys.stderr)
    sys.exit(1)

# Схема-гард (issue #263, расширено issue #276, переписано bug-2026-07-24
# create-wp-registry-schema-drift): реестры реально расходятся по набору колонок —
# вендорский skeleton пишет P/Ст/Репо (Приоритет/Статус/Репозитории), а репо,
# выросшие из него органически, добавляют свои (Зона/Источник/Дедлайн/Активация)
# и могут не иметь P/Репо вовсе. Вместо требования конкретных 6 имён — строим
# {имя: индекс} по ФАКТИЧЕСКОМУ заголовку и заполняем любую распознанную колонку,
# какая есть; жёстко обязательны только "#" и "Название" (без них некуда писать
# номер и заголовок задачи — это единственные два столбца, без которых строка
# бессмысленна в любой схеме).
header_cols = [c.strip() for c in header_line.strip().strip("|").split("|")]
REQUIRED_NAMES = ["#", "Название"]
# issue #297: вендорский skeleton пишет полные русские имена («Приоритет»,
# «Статус», «Репозитории»), а не короткие канонические («P», «Ст», «Репо») —
# та же семантика, другое написание. Синонимы резолвятся к канонической колонке
# до заполнения — те же строки find_column_indices() в check-wp-format.py уже
# читают оба варианта позиционным fallback'ом, здесь та же терпимость явным списком.
COLUMN_SYNONYMS = {
    "Приоритет": "P",
    "Статус": "Ст",
    "Репозитории": "Репо",
    "Репозиторий": "Репо",
}
col_index = {}
for i, name in enumerate(header_cols):
    canonical = COLUMN_SYNONYMS.get(name, name)
    col_index.setdefault(canonical, i)
missing_required = [name for name in REQUIRED_NAMES if name not in col_index]
if missing_required:
    print(
        "❌ WP-REGISTRY.md: заголовок таблицы не содержит обязательных колонок {}.".format(
            missing_required
        ),
        file=sys.stderr,
    )
    print("   Заголовок: {}".format(header_line.strip()), file=sys.stderr)
    print(
        "   create-wp.sh требует как минимум # и Название — без них некуда писать",
        file=sys.stderr,
    )
    print("   номер и заголовок задачи.", file=sys.stderr)
    sys.exit(1)

repo_cell = repo if repo else "{}/inbox/WP-{}/".format(gov_repo, wp_num)
activation_default = "Детали: `inbox/WP-{0}/WP-{0}.md`".format(wp_num)
values_by_name = {
    "#": "**{}**".format(wp_num),
    "P": priority,
    "Название": "**{}**".format(title),
    "Ст": "⏳ pending",
    "Репо": repo_cell,
    "Бюджет": budget,
    "Зона": zone if zone else "—",
    "Источник": result if result else "—",
    "Дедлайн": deadline if deadline else "—",
    "Активация": activation_default,
}
# Колонки, для которых реестр не дал соответствующего значения (например, "Зона"
# в вендорской схеме или "P"/"Репо" в эволюционировавшей схеме без этих полей),
# просто не заполняются — остаются "—" вместо жёсткого падения на несовпадении.
row_cells = ["—"] * len(header_cols)
for name, idx in col_index.items():
    if name in values_by_name:
        row_cells[idx] = values_by_name[name]
new_row = "| " + " | ".join(row_cells) + " |\n"
lines.insert(insert_at, new_row)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("   ✅ REGISTRY: строка {} добавлена".format(wp_num))
PYEOF
then
  exit 1
fi

# Post-write verification (issue #256): create-wp.sh once reported success here
# without the row actually landing in REGISTRY — the writer above has no retry/lock,
# so confirm the row is really there before moving on.
# issue #263: некоторые репо исторически пишут номер РП с префиксом (| WP-N |),
# не голым числом (| N |) — grep должен принимать оба формата.
if ! grep -qE "\| \*?\*?(WP-)?${WP_NUM}\*?\*? \|" "$REGISTRY"; then
  echo "❌ REGISTRY write verification FAILED: строка WP-${WP_NUM} не найдена после записи" >&2
  exit 1
fi

# --- Шаг 3: WeekPlan ---
echo "3/5 WeekPlan..."

WEEKPLAN=$(find "$STRATEGY/current" -maxdepth 1 -name "WeekPlan W*.md" 2>/dev/null | sort -r | head -1)

if [[ -n "$WEEKPLAN" ]]; then
  python3 - "$WEEKPLAN" "$WP_NUM" "$TITLE" "$PRIORITY" "$BUDGET" "$GOV_REPO" <<'PYEOF'
import sys, re
weekplan_path, wp_num, title, priority, budget, gov_repo = sys.argv[1:7]

# Маппинг приоритета → светофор
flag_map = {"P1": "🔴", "P2": "🟡", "P3": "🟢", "P4": "⚪", "P5": "⚪"}
flag = flag_map.get(priority, "⚪")

with open(weekplan_path, "r", encoding="utf-8") as f:
    content = f.read()

# Убрать часы из budget для поля h
h_val = re.sub(r"[^0-9\-]", "", budget) or "?"

new_row = "| {} | {} | **{}** — [описание] | {} | pending | W{} | {} |\n".format(
    flag, wp_num, title, h_val,
    re.search(r"W(\d+)", weekplan_path).group(1) if re.search(r"W(\d+)", weekplan_path) else "?",
    gov_repo + "/inbox"
)

anchor = next((a for a in ["**Бюджет недели:**", "**Бюджет итого:**"] if a in content), None)
if anchor:
    content = content.replace(anchor, new_row + anchor, 1)
    with open(weekplan_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("   ✅ WeekPlan: строка WP-{} добавлена".format(wp_num))
else:
    print("   ⚠️  WeekPlan: якорь 'Бюджет недели' / 'Бюджет итого' не найден — добавить вручную", file=sys.stderr)
PYEOF
else
  echo "   ⚠️  WeekPlan не найден в current/ — добавить вручную" >&2
fi

# --- Шаг 4: Strategy.md (только если --result задан и бюджет ≥3h) ---
echo "4/5 Strategy.md..."

BUDGET_H=$(echo "$BUDGET" | sed 's/[^0-9]//g')
if [[ -n "$RESULT" && "${BUDGET_H:-0}" -ge 3 ]]; then
  STRATEGY_FILE="$STRATEGY/docs/Strategy.md"
  python3 - "$STRATEGY_FILE" "$WP_NUM" "$REPO" "$RESULT" <<'PYEOF'
import sys, datetime

strategy_path, wp_num, repo, result = sys.argv[1:5]

RU_MONTHS = {
    1: "январь", 2: "февраль", 3: "март", 4: "апрель",
    5: "май", 6: "июнь", 7: "июль", 8: "август",
    9: "сентябрь", 10: "октябрь", 11: "ноябрь", 12: "декабрь"
}
today = datetime.date.today()
section_anchor = "### РП → Результаты ({} {})".format(RU_MONTHS[today.month], today.year)

with open(strategy_path, "r", encoding="utf-8") as f:
    content = f.read()

if section_anchor not in content:
    print("   ⚠️  Strategy.md: секция «{}» не найдена — добавить вручную".format(section_anchor))
    sys.exit(0)

section_start = content.index(section_anchor)
table_sep = content.find("|---|", section_start)
if table_sep == -1:
    print("   ⚠️  Strategy.md: разделитель таблицы не найден в секции — добавить вручную")
    sys.exit(0)

insert_at = content.index("\n", table_sep) + 1
repo_cell = repo if repo else "—"
new_row = "| WP-{} | {} | {} | pending |\n".format(wp_num, repo_cell, result)
content = content[:insert_at] + new_row + content[insert_at:]

with open(strategy_path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Strategy.md: WP-{} → {} добавлен".format(wp_num, result))
PYEOF
elif [[ "${BUDGET_H:-0}" -ge 3 ]]; then
  echo "   ℹ️  РП ≥3h, но --result не задан — добавить маппинг в Strategy.md вручную"
else
  echo "   ℹ️  РП <3h — маппинг в Strategy.md не требуется"
fi

# --- Шаг 5: active-wp.md ---
echo "5/5 active-wp.md..."

if [[ -f "$STRATEGY/scripts/build-active-wp.py" ]]; then
  python3 "$STRATEGY/scripts/build-active-wp.py" \
    && echo "   ✅ active-wp.md пересобран" \
    || echo "   ⚠️  build-active-wp.py завершился с ошибкой — пересобрать вручную" >&2
else
  echo "   ⚠️  scripts/build-active-wp.py не найден — пересобрать вручную" >&2
fi

# --- Linear (ручной шаг) ---
echo ""
echo "ℹ️  Linear: создать issue вручную или через MCP"
echo "   Linear MCP → create_issue title='WP-${WP_NUM} ${TITLE}' teamId=TSR"

# --- Consent file остаётся в папке WP для аудит-следа ---
# Ранее consent file удалялся здесь; это ломало последующие wp-gate-check
# редактирования в той же сессии. Файл сохраняется; уборка по усмотрению пилота.
if [[ "$SKIP_CONSENT" -eq 0 && -f "$CONSENT_FILE" ]]; then
  echo ""
  echo "ℹ️  Consent file сохранён: $CONSENT_FILE"
fi

echo ""
echo "✅ WP-${WP_NUM} создан: $TITLE"
echo "   context: inbox/WP-${WP_NUM}/WP-${WP_NUM}.md"
echo "   Следующий шаг: заполнить «Проблема», «Артефакт», «Фазы» в context file"
echo "   Не забыть: Linear issue"

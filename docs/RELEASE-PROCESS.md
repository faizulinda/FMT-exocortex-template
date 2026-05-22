# Процесс выпуска FMT-exocortex-template

> Кто, когда и как бампает версию шаблона. Цель: внятный критерий «готово к выпуску»
> вместо устного соглашения. Источник: WP-347 Ф3, 22 мая 2026.

## Что означает «выпуск»

`update.sh` качает файлы из `raw.githubusercontent.com/main` — без тегов, без staging-ветки.
Любой коммит в `main` немедленно доступен пользователям при следующем `bash update.sh`.

**Версия** в `update-manifest.json["version"]` служит информационной меткой (показывается
в `update.sh --check`), а не барьером доставки. Бамп версии = сигнал «этот набор изменений
стабилизирован, пора обновляться».

---

## Критерии готовности к бампу версии

Все пункты должны быть выполнены:

- [ ] CI зелёный (`Validate Template` + все jobs)
- [ ] Нет открытых hotfix-веток (`git branch --list 'hotfix/*'` — пусто)
- [ ] CHANGELOG.md заполнен: секция `[Unreleased]` не пустая, нет «TODO» строк
- [ ] Все новые файлы добавлены в `update-manifest.json["files"]`
  (`git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`)
- [ ] `deprecated_files` соответствует правилу (см. «Конвенция deprecated_files» ниже)

---

## Шаги бампа версии

```bash
# 1. Убедиться что CI зелёный, pull последние изменения
git pull --rebase

# 2. Определить новую версию (semver: patch = фиксы, minor = новый скилл/функция)
NEW_VERSION="0.35.0"

# 3. Забампать версию в манифесте
python3 -c "
import json, sys
m = json.load(open('update-manifest.json'))
m['version'] = sys.argv[1]
json.dump(m, open('update-manifest.json','w'), ensure_ascii=False, indent=2)
open('update-manifest.json','a').write('\n')
" "$NEW_VERSION"

# 4. Добавить раздел в CHANGELOG.md: переименовать [Unreleased] → [X.Y.Z] и добавить новый [Unreleased]
# Шаблон:
# ## [X.Y.Z] — YYYY-MM-DD
# ### Что нового
# - краткое описание
# ## [Unreleased]

# 5. Commit + push
git add update-manifest.json CHANGELOG.md
git commit -m "chore: release $NEW_VERSION"
git push
```

---

## Владелец выпуска

Автор шаблона (режим `author_mode: true` в `params.yaml`). Выпуск — синхронный шаг,
не может быть делегирован агентам без явного разрешения. Периодичность: по накоплению
изменений, ориентир ~1 раз в неделю при наличии значимых изменений.

Сигнал к выпуску: ≥1 фич или ≥3 фикса в `[Unreleased]`.

---

## Конвенция `deprecated_files`

Запись в `deprecated_files` означает: **файл УЖЕ удалён из репо или уже не используется**.
Это НЕ «планируем удалить» или «скоро мигрируем».

**Правило:**

1. Удаляешь файл из репо → в том же коммите добавляешь его в `deprecated_files`.
2. Проверяешь что ни один скрипт/хук в репо не ссылается на этот путь
   (Detector 10 в `integration-contract-validator.sh` поймает нарушение автоматически).
3. Использовать `deprecated_files` как TODO-трекер («скоро уберём») — запрещено:
   Detector 10 расценит упоминание пути в коде как ошибку.

**Почему важно:** если `deprecated_files` содержит файл, который runner ещё использует,
после `update.sh` runner упадёт с «файл не найден» (прецедент: `af3b15c`, роли стратегиста,
22 мая 2026).

---

## Чеклист при добавлении нового файла в FMT

При каждом `git add <new-file>` убедиться:

1. Файл добавлен в `update-manifest.json["files"]` (иначе пользователи не получат его).
   CI-проверка: `git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`.
2. Если файл намеренно НЕ предназначен для доставки — добавить в `excluded_paths` или в
   один из исключённых каталогов (`.github/`, `setup/`, `seed/`, `extensions/`, `templates/`).
3. Если скрипт `.sh` — запустить `bash scripts/validate-fmt-scripts.sh scripts/` для проверки
   хардкодов и небезопасной арифметики под `set -e`.

---

## Связанные файлы

| Файл | Назначение |
|------|-----------|
| `update-manifest.json` | Список доставляемых файлов + версия |
| `CHANGELOG.md` | Changelog в формате Keep a Changelog |
| `scripts/check-manifest-coverage.py` | CI-проверка полноты манифеста (B2) |
| `scripts/validate-fmt-scripts.sh` | Проверка хардкодов + set-e арифметики (B8) |
| `setup/integration-contract-validator.sh` | Validator spec↔state (включая Detector 10) |
| `docs/SCRIPT-PROMOTION.md` | Процесс промоции скрипта L3→L1 |

---
name: agent-fault
description: Регистрация косяка агента в системе учёта WP-316 L1. Без LLM — детерминированный скрипт.
argument-hint: "<severity> <description>"
routing:
  executor: script
  deterministic: true
  script_path: scripts/iwe_checklist_memory.py
---

# Agent Fault Registrar

Задача: передать косяк агента в `iwe_checklist_memory.py record`.

Использование:
```bash
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe_checklist_memory.py" record "major" "агент пропустил чеклист"
```

#!/usr/bin/env bash
# test-route-task.sh — 8 кейсов для route-task.sh (WP-350 Ф14)
# routing: executor=script deterministic=true
set -euo pipefail

SCRIPT="${1:-$HOME/IWE/FMT-exocortex-template/scripts/route-task.sh}"
export IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"

PASS=0
FAIL=0

run_test() {
    local name="$1" expected="$2"
    shift 2
    echo "=== $name ==="
    set +e
    bash "$SCRIPT" "$@" >/dev/null 2>&1
    local actual=$?
    set -e
    if [[ "$actual" -eq "$expected" ]]; then
        echo "PASS (exit $actual)"
        ((PASS++)) || true
    else
        echo "FAIL: expected exit $expected, got $actual"
        ((FAIL++)) || true
    fi
    echo ""
}

# 1. Happy path — known script skill (consent)
run_test "T1: --skill consent (script, exists)" 2 --skill consent

# 2. Unknown skill — strict (--skill)
run_test "T2: --skill unknown_skill (strict → exit 3)" 3 --skill unknown_skill

# 3. Unknown skill — flex (--tag)
run_test "T3: --tag unknown_skill (flex → fallback Sonnet, exit 0)" 0 --tag unknown_skill

# 4. Missing script — strict (--skill)
run_test "T4: --skill connect-guide (missing script → exit 2)" 2 --skill connect-guide

# 5. Missing script — flex (--tag)
run_test "T5: --tag connect-guide (missing script → fallback Haiku, exit 0)" 0 --tag connect-guide

# 6. Empty tag
run_test "T6: --tag '' (empty → unknown → fallback Sonnet, exit 0)" 0 --tag ""

# 7. --list
run_test "T7: --list (exit 0)" 0 --list

# 8. --validate
run_test "T8: --validate (exit 0)" 0 --validate

echo "========================"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL

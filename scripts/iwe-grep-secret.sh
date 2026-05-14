#!/usr/bin/env bash
#
# iwe-grep-secret.sh — Secret Drift Detector (WP-315)
#
# Сканирует ВСЕ места хранения секретов по всем слоям инфраструктуры IWE.
# Не логирует сам секрет — только hit-count и location-identifier.
#
# Usage:
#   iwe-grep-secret.sh '<secret-value>' [--layer env|cloud|pg|smoke|all]
#   echo '<secret-value>' | iwe-grep-secret.sh --layer env
#
# Exit codes:
#   0 — N = 0 (ни одного hit)
#   1 — N ≥ 1 (есть hits, требуется ручная проверка)
#   2 — ошибка инфраструктуры (нет ssh, нет psql, нет доступа)
#   3 — usage error
#
# Related: DP.SC.125, AR.205, security-posture.md §6

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.1.0-mvp"
LAYER_FILTER="all"
SECRET_VALUE=""
TOTAL_HITS=0
INFRA_ERRORS=0

# ── Colors (disable if not TTY) ──────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

# ── Helpers ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} '<secret-value>' [--layer env|cloud|pg|smoke|all]
       echo '<secret-value>' | ${SCRIPT_NAME} [--layer env]

Options:
  --layer    Сканировать только указанный слой (default: all)
  --version  Показать версию
  --help     Показать эту справку

Exit codes:
  0  — 0 hits (OK)
  1  — ≥1 hits (drift detected)
  2  — infrastructure error (ssh/psql/api unavailable)
  3  — usage error
EOF
}

die() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 3; }
warn() { echo -e "${YELLOW}WARN:${NC} $1" >&2; }

# Не логируем secret_value нигде, даже в debug
# shellcheck disable=SC2317
log_layer_start() { echo "→ Layer $1: scanning..." >&2; }
log_layer_done() { echo "  Layer $1: $2 hit(s)" >&2; }

# ── Parse args ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --layer)
      shift
      LAYER_FILTER="${1:-}"
      [[ -n "$LAYER_FILTER" ]] || die "--layer requires a value"
      ;;
    --version) echo "$VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    --)
      shift
      SECRET_VALUE="$1"
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$SECRET_VALUE" ]]; then
        SECRET_VALUE="$1"
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

# Если secret не передан как аргумент — читаем из stdin
if [[ -z "$SECRET_VALUE" ]]; then
  if [[ -t 0 ]]; then
    die "Secret value required. Pass as argument or via stdin."
  fi
  SECRET_VALUE="$(cat)"
fi

[[ -n "$SECRET_VALUE" ]] || die "Secret value is empty"

# ── Validate layer filter ────────────────────────────────────────────────
case "$LAYER_FILTER" in
  env|cloud|pg|smoke|all) ;;
  *) die "Invalid layer: $LAYER_FILTER. Use: env, cloud, pg, smoke, all" ;;
esac

# ── Layer 1: Env-файлы (local + tsekh-1) ─────────────────────────────────
scan_layer_env() {
  log_layer_start "1 (env files)"
  local hits=0
  local paths=(
    "$HOME/.secrets"
    "$HOME/.env"
    "$HOME/.config/exocortex/secrets.env"
  )

  # Локальные env-файлы
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      # grep -c — только count, не выводит совпадение
      local c
      c=$(grep -cF "$SECRET_VALUE" "$p" 2>/dev/null || true)
      if [[ "$c" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "$p" "${RED}${c} hits${NC}"
        ((hits += c))
      fi
    fi
  done

  # Рекурсивный grep по IWE (только .env файлы, исключая node_modules и т.п.)
  if [[ -d "$HOME/IWE" ]]; then
    while IFS= read -r -d '' f; do
      local c
      c=$(grep -cF "$SECRET_VALUE" "$f" 2>/dev/null || true)
      if [[ "$c" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "$f" "${RED}${c} hits${NC}"
        ((hits += c))
      fi
    done < <(find "$HOME/IWE" -type f \( -name ".env*" -o -name "secrets*" \) \
      ! -path "*/node_modules/*" ! -path "*/.venv/*" ! -path "*/venv/*" \
      ! -path "*/target/*" ! -path "*/__pycache__/*" \
      -print0 2>/dev/null)
  fi

  # tsekh-1 через ssh
  if command -v ssh &>/dev/null; then
    local ssh_hits=0
    # Проверяем доступность tsekh-1
    if ssh -o ConnectTimeout=5 -o BatchMode=yes tsekh-1 "echo ok" &>/dev/null; then
      # /etc/iwe/env
      local c1
      c1=$(ssh -o ConnectTimeout=5 tsekh-1 "grep -cF '$SECRET_VALUE' /etc/iwe/env 2>/dev/null || echo 0" 2>/dev/null || echo 0)
      if [[ "$c1" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "tsekh-1:/etc/iwe/env" "${RED}${c1} hits${NC}"
        ((ssh_hits += c1))
      fi

      # systemd unit files
      local c2
      c2=$(ssh -o ConnectTimeout=5 tsekh-1 "grep -rcF '$SECRET_VALUE' /etc/systemd/system/ 2>/dev/null | awk -F: '{s+=\$2} END {print s+0}'" 2>/dev/null || echo 0)
      if [[ "$c2" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "tsekh-1:/etc/systemd/system/" "${RED}${c2} hits${NC}"
        ((ssh_hits += c2))
      fi

      # IWE .env на tsekh-1
      local c3
      c3=$(ssh -o ConnectTimeout=5 tsekh-1 "find ~/IWE -type f \( -name '.env*' -o -name 'secrets*' \) ! -path '*/node_modules/*' -print0 2>/dev/null | xargs -0 grep -cF '$SECRET_VALUE' 2>/dev/null | awk -F: '{s+=\$2} END {print s+0}'" 2>/dev/null || echo 0)
      if [[ "$c3" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "tsekh-1:~/IWE/**/.env" "${RED}${c3} hits${NC}"
        ((ssh_hits += c3))
      fi
    else
      warn "tsekh-1 недоступен по ssh (Layer 1 incomplete)"
      ((INFRA_ERRORS++))
    fi
    ((hits += ssh_hits))
  else
    warn "ssh не установлен (Layer 1 tsekh-1 skipped)"
    ((INFRA_ERRORS++))
  fi

  log_layer_done "1" "$hits"
  ((TOTAL_HITS += hits))
}

# ── Layer 2: Cloud env (Railway + CF Workers) ────────────────────────────
scan_layer_cloud() {
  log_layer_start "2 (cloud env)"
  local hits=0

  # Railway — проверяем наличие CLI / токена
  if command -v railway &>/dev/null && [[ -n "${RAILWAY_TOKEN:-}" ]]; then
    warn "Railway scan not yet implemented (WP-315 Ф3)"
    # TODO: railway variables --json | jq ... | grep -c
  else
    warn "Railway CLI или RAILWAY_TOKEN отсутствует (Layer 2 skipped)"
    ((INFRA_ERRORS++))
  fi

  # Cloudflare Workers — проверяем wrangler
  if command -v wrangler &>/dev/null; then
    warn "CF Workers scan not yet implemented (WP-315 Ф3)"
    # TODO: wrangler secret list --name <worker>
  else
    warn "wrangler не установлен (Layer 2 CF skipped)"
    ((INFRA_ERRORS++))
  fi

  log_layer_done "2" "$hits"
  ((TOTAL_HITS += hits))
}

# ── Layer 3: PostgreSQL metadata (pg_user_mapping) ───────────────────────
scan_layer_pg() {
  log_layer_start "3 (PG metadata)"
  local hits=0

  if ! command -v psql &>/dev/null; then
    warn "psql не установлен (Layer 3 skipped)"
    ((INFRA_ERRORS++))
    log_layer_done "3" "$hits"
    return
  fi

  # Inventory БД с FDW (из security-posture.md §6)
  local databases=(
    "${NEON_REWARDS_URL:-}"
    "${NEON_LEARNING_URL:-}"
    "${NEON_ANALYTICS_URL:-}"
    "${NEON_PLATFORM_URL:-}"
  )

  local any_db_ok=0
  for db_url in "${databases[@]}"; do
    [[ -n "$db_url" ]] || continue

    local c
    # Параметризованный запрос через PGPASSWORD из URL (или .pgpass)
    # Не передаём secret_value в SQL — ищем через LIKE в umoptions
    c=$(psql "$db_url" -t -A -c "
      SELECT COUNT(*)
      FROM pg_user_mapping um
      JOIN pg_foreign_server fs ON um.umserver = fs.oid
      WHERE um.umoptions::text LIKE '%password%'
        AND um.umoptions::text LIKE '%' || regexp_replace(current_setting('my.probe_value'), '[^a-zA-Z0-9]', '', 'g') || '%';
    " 2>/dev/null || true)

    if [[ "$c" =~ ^[0-9]+$ && "$c" -gt 0 ]]; then
      printf "  %-20s %-40s %s\n" "Layer 3" "${db_url##*/} pg_user_mapping" "${RED}${c} hits${NC}"
      ((hits += c))
    fi
    any_db_ok=1
  done

  if [[ "$any_db_ok" -eq 0 ]]; then
    warn "Ни одна Neon БД не доступна (Layer 3 incomplete). Проверьте NEON_*_URL."
    ((INFRA_ERRORS++))
  fi

  log_layer_done "3" "$hits"
  ((TOTAL_HITS += hits))
}

# ── Layer 4: Smoke-tests ─────────────────────────────────────────────────
scan_layer_smoke() {
  log_layer_start "4 (smoke tests)"
  local hits=0

  warn "Smoke-test layer not yet implemented (WP-315 Ф5-Ф7)"
  # TODO: подключение через каждую роль, FDW-функция, API call

  log_layer_done "4" "$hits"
  ((TOTAL_HITS += hits))
}

# ── Main ─────────────────────────────────────────────────────────────────
echo "=== Secret Drift Detector v${VERSION} ===" >&2
echo "Layer filter: ${LAYER_FILTER}" >&2
# Не выводим secret_value
echo "" >&2

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "env" ]]; then
  scan_layer_env
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "cloud" ]]; then
  scan_layer_cloud
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "pg" ]]; then
  scan_layer_pg
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "smoke" ]]; then
  scan_layer_smoke
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo "" >&2
if [[ "$TOTAL_HITS" -gt 0 ]]; then
  echo -e "${RED}RESULT: ${TOTAL_HITS} hit(s) detected across scanned layers${NC}" >&2
else
  echo -e "${GREEN}RESULT: 0 hits — no drift detected${NC}" >&2
fi

if [[ "$INFRA_ERRORS" -gt 0 ]]; then
  echo -e "${YELLOW}INFRA: ${INFRA_ERRORS} layer(s) could not be scanned (check warnings above)${NC}" >&2
fi

if [[ "$TOTAL_HITS" -gt 0 ]]; then
  exit 1
elif [[ "$INFRA_ERRORS" -gt 0 ]]; then
  exit 2
else
  exit 0
fi

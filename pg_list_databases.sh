#!/usr/bin/env bash
# =============================================================================
# pg_list_databases.sh
# Lists all PostgreSQL databases across multiple servers, sorted by server name
# Output: Markdown document
#
# Requirements:
#   - psql installed on the machine running this script
#   - ~/.pgpass configured for passwordless auth (chmod 600 ~/.pgpass)
#   - servers.conf in the same directory as this script
#
# ~/.pgpass format (one line per server):
#   hostname:port:*:username:password
#
# Usage:
#   ./pg_list_databases.sh
#   ./pg_list_databases.sh --output /path/to/report.md
#   ./pg_list_databases.sh --config /path/to/servers.conf
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/servers.conf"
OUTPUT_FILE="${SCRIPT_DIR}/pg_databases_report.md"
CONNECT_TIMEOUT=10
DEFAULT_PORT=5432
DEFAULT_USER="postgres"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)  OUTPUT_FILE="$2";  shift 2 ;;
    --config|-c)  CONFIG_FILE="$2";  shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if ! command -v psql &>/dev/null; then
  echo "ERROR: psql not found. Please install PostgreSQL client tools." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "Create a servers.conf file. See servers.conf.example for format." >&2
  exit 1
fi

if [[ ! -f "$HOME/.pgpass" ]]; then
  echo "WARNING: ~/.pgpass not found. You may be prompted for passwords." >&2
elif [[ "$(stat -c '%a' "$HOME/.pgpass" 2>/dev/null || stat -f '%A' "$HOME/.pgpass")" != "600" ]]; then
  echo "WARNING: ~/.pgpass permissions are not 600. PostgreSQL may ignore it." >&2
  echo "Fix with: chmod 600 ~/.pgpass" >&2
fi

# ── Load servers ──────────────────────────────────────────────────────────────
# Parse servers.conf — skip blank lines and comments (#)
# Format: hostname[:port] [username]
mapfile -t RAW_SERVERS < <(grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$')

if [[ ${#RAW_SERVERS[@]} -eq 0 ]]; then
  echo "ERROR: No servers found in $CONFIG_FILE" >&2
  exit 1
fi

# Sort servers alphabetically by hostname
mapfile -t SERVERS < <(printf '%s\n' "${RAW_SERVERS[@]}" | sort)

# ── Report generation ─────────────────────────────────────────────────────────
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
TOTAL_SERVERS=${#SERVERS[@]}
SUCCESS_COUNT=0
FAIL_COUNT=0

echo "Starting PostgreSQL database inventory — $TIMESTAMP"
echo "Servers to scan: $TOTAL_SERVERS"
echo ""

# Temp file to accumulate per-server sections
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

for entry in "${SERVERS[@]}"; do
  # Parse "hostname[:port] [username]"
  HOST="$(echo "$entry" | awk '{print $1}' | cut -d: -f1)"
  PORT="$(echo "$entry" | awk '{print $1}' | cut -s -d: -f2)"
  USER="$(echo "$entry" | awk '{print $2}')"

  PORT="${PORT:-$DEFAULT_PORT}"
  USER="${USER:-$DEFAULT_USER}"

  echo -n "  Scanning $HOST:$PORT (user: $USER) ... "

  # Fetch database list — exclude PostgreSQL internal databases
  DB_OUTPUT="$(
    PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT" psql \
      --host="$HOST" \
      --port="$PORT" \
      --username="$USER" \
      --no-password \
      --tuples-only \
      --no-align \
      --command="
        SELECT
          d.datname        AS database_name,
          r.rolname        AS owner,
          pg_encoding_to_char(d.encoding) AS encoding,
          d.datcollate     AS collation,
          pg_size_pretty(pg_database_size(d.datname)) AS size,
          CASE WHEN d.datallowconn THEN 'yes' ELSE 'no' END AS connections_allowed
        FROM pg_database d
        JOIN pg_roles r ON r.oid = d.datdba
        WHERE d.datistemplate = false
          AND d.datname NOT IN ('postgres')
        ORDER BY d.datname;
      " \
      2>&1
  )" && EXIT_CODE=0 || EXIT_CODE=$?

  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "FAILED"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    {
      echo "## $HOST"
      echo ""
      echo "> **Status:** Failed to connect"
      echo ">"
      echo "> \`\`\`"
      echo "> $DB_OUTPUT"
      echo "> \`\`\`"
      echo ""
      echo "---"
      echo ""
    } >> "$TMP_BODY"
    continue
  fi

  # Count non-empty lines = number of databases
  DB_COUNT="$(echo "$DB_OUTPUT" | grep -c '[^[:space:]]' || true)"
  echo "OK ($DB_COUNT databases)"
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

  {
    echo "## $HOST"
    echo ""
    echo "- **Port:** $PORT"
    echo "- **User:** $USER"
    echo "- **Databases found:** $DB_COUNT"
    echo ""

    if [[ $DB_COUNT -eq 0 ]]; then
      echo "_No user databases found on this server._"
    else
      echo "| Database Name | Owner | Encoding | Collation | Size | Connections Allowed |"
      echo "|---|---|---|---|---|---|"
      while IFS='|' read -r db_name owner encoding collation size conn_allowed; do
        # Trim whitespace from each field
        db_name="$(echo "$db_name" | xargs)"
        owner="$(echo "$owner" | xargs)"
        encoding="$(echo "$encoding" | xargs)"
        collation="$(echo "$collation" | xargs)"
        size="$(echo "$size" | xargs)"
        conn_allowed="$(echo "$conn_allowed" | xargs)"
        [[ -z "$db_name" ]] && continue
        echo "| $db_name | $owner | $encoding | $collation | $size | $conn_allowed |"
      done <<< "$DB_OUTPUT"
    fi

    echo ""
    echo "---"
    echo ""
  } >> "$TMP_BODY"

done

# ── Write final report ────────────────────────────────────────────────────────
{
  echo "# PostgreSQL Database Inventory"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| **Generated** | $TIMESTAMP |"
  echo "| **Generated by** | $(whoami)@$(hostname) |"
  echo "| **Total servers** | $TOTAL_SERVERS |"
  echo "| **Successful** | $SUCCESS_COUNT |"
  echo "| **Failed** | $FAIL_COUNT |"
  echo ""
  echo "---"
  echo ""
  echo "<!-- Servers listed alphabetically by hostname -->"
  echo ""
  cat "$TMP_BODY"
} > "$OUTPUT_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Done!"
echo "  Report saved to: $OUTPUT_FILE"
echo "  Servers scanned: $TOTAL_SERVERS (success: $SUCCESS_COUNT, failed: $FAIL_COUNT)"

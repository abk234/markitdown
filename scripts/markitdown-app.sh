#!/usr/bin/env bash
# MarkItDown local lifecycle: venv install, MCP HTTP, sync-safe update, backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${MARKITDOWN_APP_CONFIG:-$ROOT/scripts/markitdown-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"
PID_FILE="$ROOT/scripts/.markitdown-mcp.pid"

BACKUP_DIR="${BACKUP_DIR:-$ROOT/../markitdown-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-true}"
SQUADOS_ROOT="${SQUADOS_ROOT:-$HOME/workspace_for_ai/1/SquadOS}"
LITELLM_PORT="${LITELLM_PORT:-4001}"
MCP_HOST="${MCP_HOST:-127.0.0.1}"
MCP_PORT="${MCP_PORT:-3001}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
VENV_DIR="${VENV_DIR:-.venv}"
INSTALL_EXTRAS="${INSTALL_EXTRAS:-all}"
ORT_DISABLE_TELEMETRY="${ORT_DISABLE_TELEMETRY:-1}"

usage() {
  cat <<'EOF'
Usage: scripts/markitdown-app.sh <command> [options]

Commands:
  setup                 Detect capabilities; write env; probe SquadOS LiteLLM
  start                 Ensure venv install; start markitdown-mcp HTTP in background
  stop                  Stop MCP server (keeps venv/data)
  status                Show install, MCP, LiteLLM probe
  backup                Snapshot venv metadata + local env into BACKUP_DIR
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Backup (if due) → optional git sync → reinstall editable
  convert <file> [...]  Run markitdown CLI (after setup/install)
  schedule-hint         Print LaunchAgent / cron hints
  help                  Show this help

Update options:
  --sync / --no-sync    Force or skip git sync with upstream
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/markitdown-app.env.example → scripts/markitdown-app.env
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
  fi
  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
  if [[ "$VENV_DIR" != /* ]]; then
    VENV_DIR="$ROOT/$VENV_DIR"
  fi
}

venv_python() {
  echo "$VENV_DIR/bin/python"
}

ensure_venv() {
  local force="${1:-}"
  command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "PYTHON_BIN not found: $PYTHON_BIN"
  if [[ ! -x "$(venv_python)" ]]; then
    info "creating venv at $VENV_DIR ($PYTHON_BIN)"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
    force=reinstall
  fi
  if [[ "$force" == "reinstall" ]] || ! "$(venv_python)" -c "import markitdown, markitdown_mcp" >/dev/null 2>&1; then
    info "installing editable packages (extras=[$INSTALL_EXTRAS])"
    "$(venv_python)" -m pip install -q -U pip
    "$(venv_python)" -m pip install -q -e "packages/markitdown[${INSTALL_EXTRAS}]"
    "$(venv_python)" -m pip install -q -e packages/markitdown-mcp
  fi
}

litellm_url() {
  echo "http://127.0.0.1:${LITELLM_PORT}/v1"
}

squados_api_key() {
  local envf="$SQUADOS_ROOT/.env" line key
  [[ -f "$envf" ]] || return 1
  for key in WORKSPACE_LITELLM_API_KEY LITELLM_MASTER_KEY; do
    line="$(grep -E "^${key}=" "$envf" | tail -n1 || true)"
    [[ -n "$line" ]] || continue
    echo "${line#*=}"
    return 0
  done
  return 1
}

probe_litellm() {
  local key url code
  key="$(squados_api_key || true)"
  url="$(litellm_url)/models"
  if [[ -z "$key" ]]; then
    echo "LiteLLM: no key in $SQUADOS_ROOT/.env"
    return 1
  fi
  code="$(curl -sS -o /tmp/markitdown-llmodels.json -w "%{http_code}" \
    -H "Authorization: Bearer $key" "$url" || echo fail)"
  if [[ "$code" == "200" ]]; then
    local n
    n="$(python3 -c 'import json;print(len(json.load(open("/tmp/markitdown-llmodels.json")).get("data",[])))' 2>/dev/null || echo "?")"
    echo "LiteLLM: ok $(litellm_url) ($n models)"
    return 0
  fi
  echo "LiteLLM: probe failed (HTTP $code) at $url"
  return 1
}

cmd_setup() {
  load_config
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "writing $CONFIG_FILE from example"
    cp "$ROOT/scripts/markitdown-app.env.example" "$CONFIG_FILE"
  fi
  load_config

  echo "Capability detection (microsoft/markitdown):"
  echo "  Telemetry: ORT_DISABLE_TELEMETRY=1 (ONNX Runtime; no app OTEL)"
  echo "  LLM: yes — OpenAI-compatible llm_client / llm_model (images, OCR plugin)"
  echo "  Search: not applicable"
  echo
  echo "SquadOS wiring:"
  echo "  SQUADOS_ROOT=$SQUADOS_ROOT"
  echo "  LLM base URL: $(litellm_url)"
  echo "  Example:"
  echo "    from openai import OpenAI"
  echo "    client = OpenAI(base_url=\"$(litellm_url)\", api_key=\"<from SQUADOS .env>\")"
  echo "    MarkItDown(llm_client=client, llm_model=\"<id from /v1/models>\")"
  probe_litellm || true
  ensure_venv reinstall
  info "CLI: $(venv_python) -m markitdown --help"
  "$(venv_python)" -c "import markitdown; print('markitdown', getattr(markitdown, '__version__', 'ok'))"
}

mcp_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  kill -0 "$pid" 2>/dev/null
}

cmd_start() {
  load_config
  export ORT_DISABLE_TELEMETRY
  ensure_venv
  if mcp_running; then
    info "MCP already running (pid $(cat "$PID_FILE")) on http://${MCP_HOST}:${MCP_PORT}"
    return 0
  fi
  info "starting markitdown-mcp --http --host $MCP_HOST --port $MCP_PORT"
  # New session via Python start_new_session — plain nohup dies with Cursor agent shells.
  rm -f "$PID_FILE"
  MCP_HOST="$MCP_HOST" MCP_PORT="$MCP_PORT" VENV_DIR="$VENV_DIR" ROOT="$ROOT" \
  ORT_DISABLE_TELEMETRY="$ORT_DISABLE_TELEMETRY" PID_FILE="$PID_FILE" \
  "$VENV_DIR/bin/python" - <<'PY'
import os, subprocess
from pathlib import Path
root = Path(os.environ["ROOT"])
venv = Path(os.environ["VENV_DIR"])
if not venv.is_absolute():
    venv = root / venv
log = root / "scripts/.markitdown-mcp.log"
pidf = Path(os.environ["PID_FILE"])
env = os.environ.copy()
env["ORT_DISABLE_TELEMETRY"] = os.environ.get("ORT_DISABLE_TELEMETRY", "1")
p = subprocess.Popen(
    [
        str(venv / "bin/markitdown-mcp"),
        "--http",
        "--host",
        os.environ["MCP_HOST"],
        "--port",
        os.environ["MCP_PORT"],
    ],
    cwd=str(root),
    stdin=subprocess.DEVNULL,
    stdout=open(log, "ab", buffering=0),
    stderr=subprocess.STDOUT,
    env=env,
    start_new_session=True,
)
pidf.write_text(f"{p.pid}\n")
print(p.pid)
PY
  sleep 1
  if mcp_running; then
    info "MCP up pid=$(cat "$PID_FILE")  http://${MCP_HOST}:${MCP_PORT}/mcp"
    info "Note: /mcp is an MCP protocol endpoint, not a browser UI — use an MCP client, or: ./scripts/markitdown-app.sh convert <file>"
  else
    die "MCP failed to start; see scripts/.markitdown-mcp.log"
  fi
}

cmd_stop() {
  load_config
  if ! mcp_running; then
    info "MCP not running"
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  info "stopping MCP pid=$pid"
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  info "stopped"
}

cmd_status() {
  load_config
  echo "root:    $ROOT"
  echo "venv:    $VENV_DIR $([ -x "$(venv_python)" ] && echo OK || echo missing)"
  if mcp_running; then
    echo "MCP:     running pid=$(cat "$PID_FILE") http://${MCP_HOST}:${MCP_PORT}"
  else
    echo "MCP:     stopped"
  fi
  probe_litellm || true
  if [[ -x "$(venv_python)" ]]; then
    "$(venv_python)" -c "import markitdown; print('pkg:', getattr(markitdown,'__version__','installed'))" 2>/dev/null || true
  fi
}

last_backup_stamp() {
  local marker="$BACKUP_DIR/.markitdown-backup-complete"
  [[ -f "$marker" ]] || return 1
  cat "$marker"
}

cmd_backup() {
  load_config
  local if_due=false
  [[ "${1:-}" == "--if-due" ]] && if_due=true

  if [[ "$if_due" == true ]]; then
    local last now age
    last="$(last_backup_stamp || echo 0)"
    now="$(date +%s)"
    age=$(( (now - last) / 86400 ))
    if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
      info "backup not due (last ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
      return 0
    fi
  fi

  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"
  info "backing up to $dest"
  [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$dest/"
  if [[ -x "$(venv_python)" ]]; then
    "$(venv_python)" -m pip freeze >"$dest/pip-freeze.txt" || true
  fi
  git -C "$ROOT" rev-parse HEAD >"$dest/git-HEAD.txt" 2>/dev/null || true
  date +%s >"$BACKUP_DIR/.markitdown-backup-complete"
  # prune
  local keep="$BACKUP_KEEP"
  ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | tail -n +"$((keep + 1))" | while read -r old; do
    info "pruning $old"
    rm -rf "$old"
  done
  info "backup complete"
}

cmd_update() {
  load_config
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup=true
  local rebase=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=true ;;
      --no-backup) do_backup=false ;;
      --rebase) rebase=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  [[ "$do_backup" == true ]] && cmd_backup --if-due
  if [[ "$do_sync" == true ]]; then
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  fi
  cmd_stop || true
  ensure_venv reinstall
  info "update complete; run: ./scripts/markitdown-app.sh start"
}

cmd_convert() {
  load_config
  ensure_venv
  export ORT_DISABLE_TELEMETRY
  exec "$VENV_DIR/bin/markitdown" "$@"
}

cmd_schedule_hint() {
  load_config
  cat <<EOF
# Monthly LaunchAgent (Day=1 03:15) — adjust Label/paths; never hardcode a username:
# ProgramArguments: $ROOT/scripts/markitdown-app.sh backup
# WorkingDirectory: $ROOT
# Or cron: 15 3 1 * * $ROOT/scripts/markitdown-app.sh backup >> $BACKUP_DIR/backup.log 2>&1
EOF
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true
  case "$cmd" in
    -h|--help|help) usage ;;
    setup) cmd_setup ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    backup) cmd_backup "$@" ;;
    update) cmd_update "$@" ;;
    convert) cmd_convert "$@" ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"

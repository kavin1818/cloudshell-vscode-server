#!/usr/bin/env bash
# setup-code-server.sh — install and run code-server on Google Cloud Shell.
#
# Installs a standalone build into $HOME (the only persistent disk on Cloud
# Shell) when code-server is missing, then starts it against a workspace folder.
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

readonly DEFAULT_PORT=8080
readonly MIN_PORT=2000
readonly MAX_PORT=65000
readonly READY_TIMEOUT_SEC="${CODE_SERVER_READY_TIMEOUT:-20}"
readonly BIND_HOST="0.0.0.0"
readonly INSTALL_URL="https://code-server.dev/install.sh"
readonly LOCAL_BIN="${HOME}/.local/bin"
readonly STATE_DIR="${HOME}/.local/share/code-server-cloud-shell"

# --- logging -----------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RESET='\033[0m'
  readonly C_BOLD='\033[1m'
  readonly C_GREEN='\033[32m'
  readonly C_YELLOW='\033[33m'
  readonly C_RED='\033[31m'
  readonly C_CYAN='\033[36m'
else
  readonly C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN=''
fi

info()    { printf '%b==>%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
success() { printf '%b==>%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%b==>%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
error()   { printf '%berror:%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() {
  error "$*"
  exit 1
}

usage_error() {
  error "$*"
  printf 'Try '\''%s --help'\'' for usage.\n' "$SCRIPT_NAME" >&2
  exit 2
}

# --- usage -------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Install code-server on Google Cloud Shell if needed, then start it on a
workspace folder. Port defaults to ${DEFAULT_PORT} (Cloud Shell preview
range: ${MIN_PORT}-${MAX_PORT}).

Usage:
  ${SCRIPT_NAME} [OPTIONS] WORKSPACE_DIR [PORT]
  ${SCRIPT_NAME} --status [--port PORT]
  ${SCRIPT_NAME} --stop [--port PORT]

Arguments:
  WORKSPACE_DIR   Directory to open as the VS Code workspace.
                  Created if it does not exist.
  PORT            Listen port (default: ${DEFAULT_PORT}).

Options:
  -p, --port PORT   Listen port (overrides positional PORT)
      --status      Show whether code-server is running
      --stop        Stop the code-server instance on the chosen port
  -h, --help        Show this help
  -V, --version     Show script version

Examples:
  ${SCRIPT_NAME} ~/my-project
  ${SCRIPT_NAME} ~/my-project 3000
  ${SCRIPT_NAME} --port 8080 ~/my-project
  ${SCRIPT_NAME} --status
  ${SCRIPT_NAME} --stop --port 8080

Environment:
  NO_COLOR                      Disable ANSI colors
  CODE_SERVER_READY_TIMEOUT     Seconds to wait for readiness (default: 20)

Exit codes:
  0  success
  1  runtime error
  2  usage error
  3  port in use by another process
  4  code-server failed to become ready
EOF
}

# --- args --------------------------------------------------------------------

ACTION="start"
PORT=""
WORKSPACE=""
LOCK_DIR=""
LOG_FILE=""
PID_FILE=""
META_FILE=""
INSTALLER_TMP=""
RUNNING_PIDS=()

cleanup() {
  if [[ -n "$INSTALLER_TMP" ]]; then
    rm -f "$INSTALLER_TMP"
  fi
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      -p|--port)
        [[ $# -ge 2 ]] || usage_error "--port requires a value"
        PORT="$2"
        shift 2
        ;;
      --port=*)
        PORT="${1#--port=}"
        shift
        ;;
      --status)
        ACTION="status"
        shift
        ;;
      --stop)
        ACTION="stop"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage_error "Unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  while [[ $# -gt 0 ]]; do
    if [[ -z "$WORKSPACE" ]]; then
      WORKSPACE="$1"
    elif [[ -z "$PORT" ]]; then
      PORT="$1"
    else
      usage_error "Unexpected extra argument: $1"
    fi
    shift
  done

  PORT="${PORT:-$DEFAULT_PORT}"

  if [[ "$ACTION" == "start" && -z "$WORKSPACE" ]]; then
    usage_error "WORKSPACE_DIR is required."
  fi

  if [[ "$ACTION" != "start" && -n "$WORKSPACE" ]]; then
    usage_error "WORKSPACE_DIR is not used with --${ACTION}."
  fi
}

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || usage_error "Port must be a number, got: ${PORT}"
  # 10# avoids octal interpretation of leading zeros.
  if (( 10#${PORT} < MIN_PORT || 10#${PORT} > MAX_PORT )); then
    die "Port ${PORT} is outside Cloud Shell preview range (${MIN_PORT}-${MAX_PORT})."
  fi
  PORT="$((10#${PORT}))"
}

init_state_paths() {
  LOG_FILE="${STATE_DIR}/code-server-${PORT}.log"
  PID_FILE="${STATE_DIR}/code-server-${PORT}.pid"
  META_FILE="${STATE_DIR}/code-server-${PORT}.meta"
  LOCK_DIR="${STATE_DIR}/setup-${PORT}.lock"
}

# --- helpers -----------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_cloud_shell() {
  [[ "${CLOUD_SHELL:-}" == "true" ]] \
    || [[ -n "${DEVSHELL_PROJECT_ID:-}" ]] \
    || [[ -n "${WEB_HOST:-}" ]]
}

ensure_path() {
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *) export PATH="${LOCAL_BIN}:${PATH}" ;;
  esac
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    return 0
  fi

  local holder=""
  if [[ -f "${LOCK_DIR}/pid" ]]; then
    holder="$(tr -d '[:space:]' <"${LOCK_DIR}/pid" || true)"
  fi
  if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
    warn "Removing stale lock from PID ${holder}."
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
    return 0
  fi
  die "Another setup is already running for port ${PORT} (lock: ${LOCK_DIR})."
}

read_pid_file() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(tr -d '[:space:]' <"$PID_FILE" || true)"
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$pid"
    return 0
  fi
  return 1
}

process_cmdline() {
  local pid="$1"
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline"
    printf '\n'
    return 0
  fi
  ps -p "$pid" -o args= 2>/dev/null || true
}

is_code_server_pid() {
  local pid="$1"
  local cmdline
  cmdline="$(process_cmdline "$pid")"
  [[ "$cmdline" == *code-server* ]]
}

pids_on_port() {
  local port="$1"
  local pids=""

  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  fi

  if [[ -z "$pids" ]] && command -v fuser >/dev/null 2>&1; then
    pids="$(fuser "${port}/tcp" 2>/dev/null || true)"
  fi

  if [[ -z "$pids" ]] && command -v ss >/dev/null 2>&1; then
    pids="$(
      ss -lptn "sport = :${port}" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | cut -d= -f2 \
        | sort -u || true
    )"
  fi

  printf '%s\n' "$pids" | tr -s '[:space:]' '\n' | awk 'NF && $1 ~ /^[0-9]+$/ && !seen[$1]++'
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE ":${port}[[:space:]]" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi
  bash -c "echo >/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

health_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && return 0
    return 1
  fi
  port_in_use "$PORT"
}

wait_until_ready() {
  local deadline=$((SECONDS + READY_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if health_ok; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

write_pid_file() {
  local pid="$1"
  local tmp
  tmp="${PID_FILE}.tmp.$$"
  printf '%s\n' "$pid" >"$tmp"
  mv "$tmp" "$PID_FILE"
}

write_meta_file() {
  local pid="$1"
  cat >"$META_FILE" <<EOF
pid=${pid}
port=${PORT}
workspace=${WORKSPACE}
bind_addr=${BIND_HOST}:${PORT}
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# --- install / locate --------------------------------------------------------

find_code_server() {
  local resolved=""
  if resolved="$(command -v code-server 2>/dev/null)" && [[ -x "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [[ -x "${LOCAL_BIN}/code-server" ]]; then
    printf '%s\n' "${LOCAL_BIN}/code-server"
    return 0
  fi
  return 1
}

install_code_server() {
  info "code-server is not installed. Installing standalone build into ${HOME}/.local ..."
  require_cmd curl

  INSTALLER_TMP="$(mktemp "${TMPDIR:-/tmp}/code-server-install.XXXXXX")"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
    "$INSTALL_URL" -o "$INSTALLER_TMP"
  bash "$INSTALLER_TMP" --method=standalone
  rm -f "$INSTALLER_TMP"
  INSTALLER_TMP=""

  ensure_path
  if ! find_code_server >/dev/null; then
    die "Install finished but code-server was not found on PATH or in ${LOCAL_BIN}."
  fi
  success "code-server installed."
}

# --- process control ---------------------------------------------------------

unique_pids() {
  awk 'NF && $1 ~ /^[0-9]+$/ && !seen[$1]++'
}

load_running_pids() {
  local pid cmdline
  local -a found=()
  RUNNING_PIDS=()

  if pid="$(read_pid_file)"; then
    if kill -0 "$pid" 2>/dev/null && is_code_server_pid "$pid"; then
      found+=("$pid")
    fi
  fi

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    cmdline="$(process_cmdline "$pid")"
    if [[ "$cmdline" == *code-server* ]]; then
      found+=("$pid")
    else
      error "Port ${PORT} is already in use by PID ${pid} (${cmdline:-unknown})."
      exit 3
    fi
  done < <(pids_on_port "$PORT")

  if [[ ${#found[@]} -eq 0 ]]; then
    return 0
  fi
  mapfile -t RUNNING_PIDS < <(printf '%s\n' "${found[@]}" | unique_pids)
}

wait_for_exit() {
  local pid="$1"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.3
  done
  return 1
}

stop_pids() {
  local -a pids=("$@")
  local pid

  [[ ${#pids[@]} -gt 0 ]] || return 0

  info "Stopping code-server on port ${PORT} (PID: ${pids[*]}) ..."
  kill "${pids[@]}" 2>/dev/null || true

  for pid in "${pids[@]}"; do
    if ! wait_for_exit "$pid"; then
      warn "PID ${pid} did not exit; sending SIGKILL."
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  rm -f "$PID_FILE" "$META_FILE"
}

stop_existing() {
  load_running_pids
  if [[ ${#RUNNING_PIDS[@]} -eq 0 ]]; then
    rm -f "$PID_FILE"
    return 0
  fi
  stop_pids "${RUNNING_PIDS[@]}"
}

cmd_stop() {
  acquire_lock
  load_running_pids
  if [[ ${#RUNNING_PIDS[@]} -eq 0 ]]; then
    info "code-server is not running on port ${PORT}."
    rm -f "$PID_FILE"
    return 0
  fi
  stop_pids "${RUNNING_PIDS[@]}"
  success "Stopped code-server on port ${PORT}."
}

cmd_status() {
  local pid=""
  local workspace=""

  if pid="$(read_pid_file)" && kill -0 "$pid" 2>/dev/null && is_code_server_pid "$pid"; then
    if [[ -f "$META_FILE" ]]; then
      workspace="$(awk -F= '/^workspace=/{sub(/^workspace=/, ""); print; exit}' "$META_FILE")"
    fi
    success "code-server is running."
    printf '  %bPID%b        %s\n' "$C_BOLD" "$C_RESET" "$pid"
    printf '  %bPort%b       %s\n' "$C_BOLD" "$C_RESET" "$PORT"
    [[ -n "$workspace" ]] && printf '  %bWorkspace%b  %s\n' "$C_BOLD" "$C_RESET" "$workspace"
    printf '  %bLog%b        %s\n' "$C_BOLD" "$C_RESET" "$LOG_FILE"
    if health_ok; then
      printf '  %bHealth%b     ready\n' "$C_BOLD" "$C_RESET"
    else
      printf '  %bHealth%b     starting or unresponsive\n' "$C_BOLD" "$C_RESET"
    fi
    return 0
  fi

  if pid="$(read_pid_file)"; then
    warn "Stale PID file (${pid}); code-server is not running on port ${PORT}."
    return 1
  fi

  info "code-server is not running on port ${PORT}."
  return 1
}

# --- start -------------------------------------------------------------------

ensure_workspace() {
  if [[ -e "$WORKSPACE" && ! -d "$WORKSPACE" ]]; then
    die "Workspace path exists but is not a directory: ${WORKSPACE}"
  fi
  if [[ ! -d "$WORKSPACE" ]]; then
    info "Creating workspace directory: ${WORKSPACE}"
    mkdir -p "$WORKSPACE"
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
}

start_code_server() {
  local binary="$1"
  local pid

  if [[ -n "${WEB_HOST:-}" ]]; then
    export VSCODE_PROXY_URI="https://{{port}}-${WEB_HOST}"
  fi

  umask 077
  : >"$LOG_FILE"

  info "Starting code-server on ${WORKSPACE} (port ${PORT}) ..."
  nohup "$binary" \
    --bind-addr "${BIND_HOST}:${PORT}" \
    --auth none \
    --trusted-origins "*" \
    --ignore-last-opened \
    "$WORKSPACE" \
    >>"$LOG_FILE" 2>&1 &
  pid=$!
  write_pid_file "$pid"
  write_meta_file "$pid"

  if ! kill -0 "$pid" 2>/dev/null; then
    warn "Process exited immediately. Last log lines:"
    tail -n 20 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE" "$META_FILE"
    exit 4
  fi

  if ! wait_until_ready; then
    warn "code-server did not become ready in ${READY_TIMEOUT_SEC}s. Last log lines:"
    tail -n 20 "$LOG_FILE" >&2 || true
    error "Failed to start code-server. See ${LOG_FILE}"
    exit 4
  fi
}

print_access_info() {
  local pid
  pid="$(read_pid_file || true)"

  echo
  success "code-server is running."
  printf '  %bWorkspace%b  %s\n' "$C_BOLD" "$C_RESET" "$WORKSPACE"
  printf '  %bPort%b       %s\n' "$C_BOLD" "$C_RESET" "$PORT"
  printf '  %bPID%b        %s\n' "$C_BOLD" "$C_RESET" "$pid"
  printf '  %bLog%b        %s\n' "$C_BOLD" "$C_RESET" "$LOG_FILE"
  echo

  if [[ -n "${WEB_HOST:-}" ]]; then
    printf '  %bPreview%b    https://%s-%s\n' "$C_BOLD" "$C_RESET" "$PORT" "$WEB_HOST"
    echo
    info "Open that URL, or use Cloud Shell Web Preview on port ${PORT}."
  else
    info "In Cloud Shell, click Web Preview and choose port ${PORT}."
    info "Preview URL format: https://PORT-\$WEB_HOST"
  fi

  echo
  info "Stop with: ${SCRIPT_NAME} --stop --port ${PORT}"
}

cmd_start() {
  local binary

  if ! is_cloud_shell; then
    warn "This does not look like Google Cloud Shell; continuing anyway."
    warn "--auth none is intended for Cloud Shell Web Preview only."
  fi

  ensure_workspace
  ensure_path
  acquire_lock

  if binary="$(find_code_server)"; then
    success "code-server is already available: ${binary}"
    info "$("$binary" --version 2>/dev/null | head -n 1 || echo "(version unknown)")"
  else
    install_code_server
    binary="$(find_code_server)" || die "code-server is still missing after install."
  fi

  stop_existing
  start_code_server "$binary"
  print_access_info
}

# --- main --------------------------------------------------------------------

main() {
  if ((BASH_VERSINFO[0] < 4)); then
    die "Bash 4.0 or later is required (found ${BASH_VERSION})."
  fi

  parse_args "$@"
  validate_port
  init_state_paths
  ensure_state_dir
  ensure_path

  case "$ACTION" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)      die "Internal error: unknown action ${ACTION}" ;;
  esac
}

main "$@"

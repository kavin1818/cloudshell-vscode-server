#!/bin/sh
# Re-executes under Bash when invoked as `sh code-server.sh`.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Secure lifecycle manager for a single, user-owned code-server instance.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM_NAME="${0##*/}"
readonly STARTUP_TIMEOUT="${CODE_SERVER_STARTUP_TIMEOUT:-15}"
readonly DEFAULT_PORT=8080
readonly DEFAULT_BIND_ADDRESS="0.0.0.0"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/code-server"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/code-server-manager"
readonly DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/code-server-session"
readonly CONFIG_FILE="$CONFIG_DIR/config.yaml"
readonly PID_FILE="$STATE_DIR/code-server.pid"
readonly LOG_FILE="$STATE_DIR/code-server.log"
readonly LOCK_FILE="$STATE_DIR/code-server.lock"

FOLDER=""
PORT="${CODE_SERVER_PORT:-$DEFAULT_PORT}"
BIND_ADDRESS="${CODE_SERVER_BIND_ADDR:-$DEFAULT_BIND_ADDRESS}"
PASSWORD="${CODE_SERVER_PASSWORD:-}"
PASSWORD_FILE="${CODE_SERVER_PASSWORD_FILE:-}"
# Do not propagate password-source environment variables to the child process.
unset CODE_SERVER_PASSWORD CODE_SERVER_PASSWORD_FILE
COMMAND="start"
LOCK_FD=""

usage() {
  cat <<USAGE
Usage: $PROGRAM_NAME [start|stop|status] [options]

Securely manage one code-server instance for the current user.

Options:
  -f, --folder PATH       Workspace directory (default: current directory)
  -p, --port PORT         TCP port in the range 1-65535 (default: $DEFAULT_PORT)
  -b, --bind-addr ADDR    Bind address (default: $DEFAULT_BIND_ADDRESS)
      --password-file FILE  Read password from a file; it must not be group/world-readable
      --public            Bind to 0.0.0.0 (the default; required by Cloud Shell port proxy)
  -h, --help              Show this help

Environment: CODE_SERVER_PASSWORD, CODE_SERVER_PASSWORD_FILE, CODE_SERVER_PORT,
CODE_SERVER_BIND_ADDR, CODE_SERVER_STARTUP_TIMEOUT, XDG_CONFIG_HOME, XDG_STATE_HOME,
XDG_DATA_HOME.
USAGE
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

log() {
  local level=$1 event=$2 message=$3
  shift 3
  printf '{"timestamp":"%s","level":"%s","event":"%s","message":"%s"' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$level")" \
    "$(json_escape "$event")" "$(json_escape "$message")" >&2
  while (($#)); do
    printf ',"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")" >&2
    shift 2
  done
  printf '}\n' >&2
}

die() {
  log error validation_failed "$1"
  exit 1
}

on_error() {
  local status=$? line=$1 command=$2
  log error unexpected_failure "Command failed" exit_code "$status" line "$line" command "$command"
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

release_lock() {
  if [[ -n $LOCK_FD ]]; then
    flock -u "$LOCK_FD" || true
    eval "exec ${LOCK_FD}>&-"
  fi
}
trap release_lock EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

validate_port() {
  [[ $PORT =~ ^[0-9]+$ ]] || die "Port must be an integer between 1 and 65535."
  ((10#$PORT >= 1 && 10#$PORT <= 65535)) || die "Port must be between 1 and 65535."
}

validate_startup_timeout() {
  [[ $STARTUP_TIMEOUT =~ ^[0-9]+$ && 10#$STARTUP_TIMEOUT -ge 1 && 10#$STARTUP_TIMEOUT -le 300 ]] || \
    die "CODE_SERVER_STARTUP_TIMEOUT must be an integer between 1 and 300 seconds."
}

validate_bind_address() {
  [[ $BIND_ADDRESS != *$'\n'* && $BIND_ADDRESS != *$'\r'* && $BIND_ADDRESS != *:* ]] || \
    die "Bind address must be a hostname or IPv4 address without a port."
  [[ $BIND_ADDRESS =~ ^[A-Za-z0-9._-]+$ ]] || die "Bind address contains unsupported characters."
}

readiness_host() {
  if [[ $BIND_ADDRESS == "0.0.0.0" ]]; then
    printf '%s' "127.0.0.1"
  else
    printf '%s' "$BIND_ADDRESS"
  fi
}

is_ready() {
  local host
  host=$(readiness_host)
  curl --noproxy '*' --connect-timeout 1 --max-time 2 --output /dev/null --silent \
    "http://${host}:${PORT}/" >/dev/null 2>&1
}

validate_password_file() {
  [[ -f $PASSWORD_FILE && -r $PASSWORD_FILE && -O $PASSWORD_FILE ]] || \
    die "Password file must be a readable regular file owned by the current user."
  local permissions
  permissions=$(stat -c '%a' "$PASSWORD_FILE")
  (( (8#$permissions & 077) == 0 )) || die "Password file must not be readable by group or others."
}

read_password() {
  if [[ -n $PASSWORD && -n $PASSWORD_FILE ]]; then
    die "Specify only one password source: CODE_SERVER_PASSWORD or --password-file."
  fi
  if [[ -n $PASSWORD_FILE ]]; then
    validate_password_file
    PASSWORD=$(<"$PASSWORD_FILE")
  fi
  [[ -n $PASSWORD ]] || die "A password is required; set CODE_SERVER_PASSWORD or provide --password-file."
  [[ ${#PASSWORD} -ge 12 ]] || die "Password must contain at least 12 characters."
  [[ $PASSWORD != *$'\n'* && $PASSWORD != *$'\r'* ]] || die "Password must not contain line breaks."
}

yaml_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

acquire_lock() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # shellcheck disable=SC3045
  exec {LOCK_FD}>"$LOCK_FILE"
  flock -n "$LOCK_FD" || die "Another $PROGRAM_NAME process is already managing this instance."
}

read_pid() {
  [[ -f $PID_FILE ]] || return 1
  local pid
  pid=$(<"$PID_FILE")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "$pid"
}

is_running() {
  local pid
  pid=$(read_pid) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local process_owner command_line
  process_owner=$(ps -o user= -p "$pid" 2>/dev/null | xargs) || return 1
  [[ $process_owner == "$(id -un)" ]] || return 1
  command_line=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  [[ $command_line == *code-server* ]]
}

remove_stale_pid_file() {
  if [[ -f $PID_FILE ]] && ! is_running; then
    log warning stale_pid_file "Removing stale or untrusted PID file" pid_file "$PID_FILE"
    rm -f "$PID_FILE"
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR"
  local temporary_config
  temporary_config=$(mktemp "$CONFIG_DIR/config.yaml.XXXXXX")
  chmod 600 "$temporary_config"
  {
    printf 'bind-addr: %s:%s\n' "$BIND_ADDRESS" "$PORT"
    printf 'auth: password\n'
    printf 'password: %s\n' "$(yaml_quote "$PASSWORD")"
    printf 'cert: false\n'
  } >"$temporary_config"
  mv -f "$temporary_config" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

start() {
  require_command code-server
  require_command realpath
  require_command flock
  require_command stat
  require_command ps
  require_command curl
  validate_port
  validate_bind_address
  validate_startup_timeout
  read_password
  FOLDER=$(realpath -e -- "${FOLDER:-$PWD}") || die "Workspace path cannot be resolved."
  [[ -d $FOLDER ]] || die "Workspace is not a directory: $FOLDER"
  acquire_lock
  remove_stale_pid_file
  if is_running; then
    die "code-server is already running with PID $(read_pid). Use '$PROGRAM_NAME stop' first."
  fi
  write_config
  if [[ $BIND_ADDRESS == "0.0.0.0" ]]; then
    log warning public_listener "code-server will listen on all interfaces; restrict network access or use a TLS proxy" port "$PORT"
  fi
  log info starting "Starting code-server" workspace "$FOLDER" bind_address "$BIND_ADDRESS" port "$PORT"
  nohup code-server --config "$CONFIG_FILE" --user-data-dir "$DATA_DIR" "$FOLDER" \
    >>"$LOG_FILE" 2>&1 < /dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  local attempt
  for ((attempt = 1; attempt <= 10#$STARTUP_TIMEOUT; attempt++)); do
    if is_running && is_ready; then
      log info ready "code-server accepted an HTTP connection" pid "$pid" log_file "$LOG_FILE"
      printf 'code-server started (PID %s). Workspace: %s. Listening on %s:%s. Log: %s\n' \
        "$pid" "$FOLDER" "$BIND_ADDRESS" "$PORT" "$LOG_FILE"
      return 0
    fi
    sleep 1
  done
  rm -f "$PID_FILE"
  log error start_failed "code-server did not become ready before the startup timeout" \
    timeout_seconds "$STARTUP_TIMEOUT" log_file "$LOG_FILE" \
    remediation "Inspect the log with: tail -n 100 $LOG_FILE"
  exit 1
}

stop() {
  acquire_lock
  if ! is_running; then
    remove_stale_pid_file
    log info already_stopped "code-server is not running"
    return 0
  fi
  local pid
  pid=$(read_pid)
  log info stopping "Stopping code-server" pid "$pid"
  kill -TERM "$pid"
  local attempt
  for attempt in {1..30}; do
    is_running || break
    sleep 1
  done
  if is_running; then
    log warning force_stopping "code-server did not stop gracefully; sending SIGKILL" pid "$pid"
    kill -KILL "$pid"
  fi
  rm -f "$PID_FILE"
  log info stopped "code-server stopped" pid "$pid"
}

status() {
  acquire_lock
  if is_running; then
    local pid
    pid=$(read_pid)
    log info running "code-server is running" pid "$pid"
    printf 'code-server is running (PID %s).\n' "$pid"
  else
    remove_stale_pid_file
    log info stopped "code-server is stopped"
    printf 'code-server is stopped.\n'
    exit 3
  fi
}

parse_arguments() {
  if [[ ${1:-} == start || ${1:-} == stop || ${1:-} == status ]]; then
    COMMAND=$1
    shift
  fi
  while (($#)); do
    case $1 in
      -f|--folder) (($# >= 2)) || die "$1 requires a value."; FOLDER=$2; shift 2 ;;
      -p|--port) (($# >= 2)) || die "$1 requires a value."; PORT=$2; shift 2 ;;
      -b|--bind-addr) (($# >= 2)) || die "$1 requires a value."; BIND_ADDRESS=$2; shift 2 ;;
      --password-file) (($# >= 2)) || die "$1 requires a value."; PASSWORD_FILE=$2; shift 2 ;;
      --public) BIND_ADDRESS=0.0.0.0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  [[ $COMMAND == start || -z $FOLDER ]] || die "--folder is only valid with the start command."
}

main() {
  parse_arguments "$@"
  case $COMMAND in
    start) start ;;
    stop) stop ;;
    status) status ;;
  esac
}

main "$@"

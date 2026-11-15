#!/usr/bin/env bash
set -uo pipefail

RESTICO_CONFIG_DIR="${RESTICO_CONFIG_DIR:-$HOME/.config/restico}"
RESTICO_CACHE_DIR="${RESTICO_CACHE_DIR:-$HOME/.cache/restico}"

ENV_FILE="${RESTICO_ENV:-$RESTICO_CONFIG_DIR/.env}"
set -a
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
set +a

# Map RESTICO_* vars to RESTIC_* (restic expects these)
RESTIC_REPOSITORY="${RESTICO_REPOSITORY:-${RESTIC_REPOSITORY:-}}"
RESTIC_PASSWORD="${RESTICO_PASSWORD:-${RESTIC_PASSWORD:-}}"
RESTIC_PASSWORD_FILE="${RESTICO_PASSWORD_FILE:-${RESTIC_PASSWORD_FILE:-}}"
RESTIC_PASSWORD_COMMAND="${RESTICO_PASSWORD_COMMAND:-${RESTIC_PASSWORD_COMMAND:-}}"
export RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND

LOG_FILE="${RESTICO_LOG_FILE:-$RESTICO_CACHE_DIR/restico.log}"
mkdir -p "$(dirname "$LOG_FILE")"

#─── utils ─────────────────────────────────────────

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

ntfy_notify() {
  local url="${RESTICO_NTFY_URL:-}"
  local token="${RESTICO_NTFY_TOKEN:-}"

  # Both unset → skip silently
  [ -z "$url" ] && [ -z "$token" ] && return

  # One set but not the other → warn once
  if [ -z "$url" ] || [ -z "$token" ]; then
    log "WARNING: ntfy partially configured — set both RESTICO_NTFY_URL and RESTICO_NTFY_TOKEN or neither"
    return
  fi

  local args=(-s -o /dev/null -X POST "$url"
    -H "Authorization: Bearer $token"
    -H "Title: $RESTICO_HOSTNAME: ${1:-}"
    -H "X-Priority: ${2:-low}"
    -H "Tags: ${3:-}"
    -H "X-Markdown: yes")
  [ -n "${4:-}" ] && args+=(-d "$4")

  curl "${args[@]}"
}

JQ_DEFS='
  def row($k; $v): $k + (" " * (20 - ($k | length))) + $v;
  def human:
    if . < 1024 then "\(.) B"
    elif . < 1048576 then "\((. * 100 / 1024 | round) / 100) KiB"
    elif . < 1073741824 then "\((. * 100 / 1048576 | round) / 100) MiB"
    else "\((. * 100 / 1073741824 | round) / 100) GiB" end;
'

stats_body() {
  local out="$1"
  local filter="$2"
  command -v jq >/dev/null 2>&1 || return 0
  jq -rs "${JQ_DEFS} ${filter}" "$out" 2>/dev/null
}

backup_stats_body() {
  stats_body "$1" '
    . as $lines |
    ($lines | map(select(type == "object" and .message_type == "summary"))[-1]) as $s |
    select($s != null) |
    "```text",
    "---------- Backup ----------",
    row("Time"; ($s.total_duration | round | tostring) + "s"),
    row("New files"; ($s.files_new | tostring)),
    row("Changed files"; ($s.files_changed | tostring)),
    row("Data added"; ($s.data_added | human)),
    row("Size"; ($s.total_bytes_processed | human)),
    row("Snapshot"; (($s.snapshot_id // "dry-run")[0:8])),
    row("Location"; env.RESTICO_BACKUP_PATHS),
    (if $s.error_count > 0 then row("Errors"; ($s.error_count | tostring)) else empty end),
    "```"
  '
}

verify_stats_body() {
  stats_body "$1" '
    . as $lines |
    ($lines | map(select(type == "object" and .message_type == "summary"))[-1]) as $s |
    select($s != null) |
    "```text",
    "---------- Verify ----------",
    row("Errors"; ($s.num_errors | tostring)),
    row("Broken packs"; ($s.broken_packs | length | tostring)),
    (if $s.suggest_repair_index then row("Repair index"; "yes") else empty end),
    (if $s.suggest_prune then row("Suggest prune"; "yes") else empty end),
    "```"
  '
}

forget_stats_body() {
  stats_body "$1" '
    . as $lines |
    ($lines | map(select(type == "array"))[0]) as $g |
    ($lines | map(select(type == "object" and .message_type == "summary"))[-1]) as $p |
    select($g != null) |
    "```text",
    "---------- Forget ----------",
    row("Removed snapshots"; ([$g[].remove | length] | add | tostring)),
    row("Kept snapshots"; ([$g[].keep | length] | add | tostring)),
    (if $p != null then
      row("Freed space"; ($p.bytes.remove_total | human)),
      row("Repo size"; ($p.bytes.remaining | human))
    else empty end),
    "```"
  '
}

error_lines() {
  local out="$1"
  local max="${2:-5}"

  if ! command -v jq >/dev/null 2>&1; then
    tail -n "$max" "$out" | sed '/^$/d'
    return
  fi

  local lines
  lines="$(jq -rs --argjson max "$max" '
    [.[] |
      select(type == "object" and (.message_type == "error" or .message_type == "exit_error")) |
      ((.error.message // .message) // empty)
    ] | unique | .[:$max][]
  ' "$out" 2>/dev/null)"

  if [ -z "$lines" ]; then
    tail -n "$max" "$out" | sed '/^$/d'
  else
    printf '%s\n' "$lines"
  fi
}

failure_body() {
  local task="$1"
  local code="$2"
  local context="$3"
  local out="$4"

  local body
  body="**${task} failed** with exit code \`${code}\`"

  if [ -n "$context" ]; then
    body="${body}
${context}"
  fi

  local detail
  detail="$(error_lines "$out")"

  if [ -n "$detail" ]; then
    body="${body}

Errors:
$(printf '%s\n' "$detail" | sed 's/^/- /')"
  fi

  printf '%s\n' "$body"
}

success() {
  local task="$1"
  log "${task} completed successfully ✓"
}

error() {
  local task="$1"
  log "${task} failed ✗"
}

logfile_output() {
  stdbuf -oL tee -a "$LOG_FILE"
}

is_success() {
  [ "$1" -eq 0 ] || [ "$1" -eq 3 ]
}

run_restic() {
  local tmp="$1"
  shift
  "$@" >"$tmp" 2>&1
  local code=$?
  cat "$tmp" >>"$LOG_FILE"
  return "$code"
}

#─── restic ────────────────────────────────────────

check() {
  local missing=0

  [ -z "${RESTICO_REPOSITORY:-}" ] && echo "Missing: RESTICO_REPOSITORY" && missing=1
  ! { [ -n "${RESTICO_PASSWORD:-}" ] || [ -n "${RESTICO_PASSWORD_FILE:-}" ] || [ -n "${RESTICO_PASSWORD_COMMAND:-}" ]; } &&
    echo "Missing: RESTICO_PASSWORD, RESTICO_PASSWORD_FILE, or RESTICO_PASSWORD_COMMAND" && missing=1
  [ -z "${RESTICO_HOSTNAME:-}" ] && echo "Missing: RESTICO_HOSTNAME" && missing=1
  [ -z "${RESTICO_BACKUP_PATHS:-}" ] && echo "Missing: RESTICO_BACKUP_PATHS" && missing=1

  [ "$missing" -ne 0 ] && exit 1

  if ! restic cat config >/dev/null 2>&1; then
    echo ""
    echo "No restic repository at the configured location."
    echo "Run: restico init"
    exit 1
  fi

  success "Check"
}

init() {
  restic init
  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    error "Init"
    exit 1
  fi
}

backup() {
  log "Running restic backup..."

  local prune=0
  local restic_args=()

  for arg in "$@"; do
    if [ "$arg" = "--prune" ]; then
      prune=1
    elif [ "$arg" = "--json" ]; then
      :
    else
      restic_args+=("$arg")
    fi
  done

  local args=()
  [ -n "${RESTICO_EXCLUDE_FILE:-}" ] && args+=(--exclude-file="$RESTICO_EXCLUDE_FILE")

  local tmp
  tmp="$(mktemp)"

  run_restic "$tmp" restic backup \
    $RESTICO_BACKUP_PATHS \
    "${args[@]}" \
    --host "$RESTICO_HOSTNAME" \
    --json \
    "${restic_args[@]}"

  EXIT_CODE=$?

  if is_success "$EXIT_CODE"; then
    success "Backup"
    ntfy_notify "Backup OK" "low" "white_check_mark" "$(backup_stats_body "$tmp")"
    rm -f "$tmp"
    [ "$prune" -eq 1 ] && forget --silent
    return 0
  else
    error "Backup with exit code ${EXIT_CODE}"
    ntfy_notify "Backup failed" "high" "warning" "$(failure_body "Backup" "$EXIT_CODE" "Location(s): ${RESTICO_BACKUP_PATHS}" "$tmp")"
    rm -f "$tmp"
    return 1
  fi
}

forget() {
  local silent=0
  local restic_args=()

  for arg in "$@"; do
    if [ "$arg" = "--silent" ]; then
      silent=1
    elif [ "$arg" = "--json" ]; then
      :
    else
      restic_args+=("$arg")
    fi
  done

  log "Applying retention policy..."

  local tmp
  tmp="$(mktemp)"

  run_restic "$tmp" restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune \
    --json \
    "${restic_args[@]}"

  EXIT_CODE=$?

  if is_success "$EXIT_CODE"; then
    success "Retention policy"
    [ "$silent" -eq 0 ] && ntfy_notify "Retention OK" "low" "wastebasket" "$(forget_stats_body "$tmp")"
    rm -f "$tmp"
    return 0
  else
    error "Retention policy with exit code ${EXIT_CODE}"
    [ "$silent" -eq 0 ] && ntfy_notify "Retention failed" "high" "warning,wastebasket" "$(failure_body "Retention" "$EXIT_CODE" "Location(s): ${RESTICO_BACKUP_PATHS}" "$tmp")"
    rm -f "$tmp"
    return 1
  fi
}

verify() {
  log "Verifying backup..."

  local tmp
  tmp="$(mktemp)"

  local restic_args=()
  for arg in "$@"; do
    [ "$arg" = "--json" ] || restic_args+=("$arg")
  done

  run_restic "$tmp" restic check --with-cache --json "${restic_args[@]}"

  EXIT_CODE=$?

  if is_success "$EXIT_CODE"; then
    success "Verify"
    ntfy_notify "Verify OK" "low" "mag" "$(verify_stats_body "$tmp")"
    rm -f "$tmp"
    return 0
  else
    error "Verify with exit code ${EXIT_CODE}"
    ntfy_notify "Verify failed" "high" "warning,mag" "$(failure_body "Verify" "$EXIT_CODE" "" "$tmp")"
    rm -f "$tmp"
    return 1
  fi
}

logs() {
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
  else
    echo "No log file found at $LOG_FILE"
    exit 1
  fi
}

snapshots() {
  restic snapshots "$@" 2>&1 | logfile_output
}

restore() {
  restic restore "$@" 2>&1 | logfile_output
}

exec_cmd() {
  restic "$@" 2>&1 | logfile_output
}

#─── CLI dispatch ───────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
  check) check "$@" ;;
  init) init "$@" ;;
  backup) backup "$@" ;;
  forget) forget "$@" ;;
  verify) verify "$@" ;;
  logs) logs "$@" ;;
  snapshots) snapshots "$@" ;;
  restore) restore "$@" ;;
  exec) exec_cmd "$@" ;;
  help | *) echo "Usage: restico {check|init|backup|forget|verify|logs|snapshots|restore|exec} [restic flags...]" ;;
  esac
}

main "$@"

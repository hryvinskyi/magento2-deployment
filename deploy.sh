#!/usr/bin/env bash

# ===================================================================
# Magento 2 zero-downtime deployment
# ===================================================================
# Cross-platform (macOS / Linux, bash 3.2+). Runs from the Magento
# root (or any directory with --dir / MAGENTO_DIR).
#
# How it stays online:
#   * composer install runs in place while the site serves traffic.
#   * setup:di:compile, the optimized composer classmap and
#     setup:static-content:deploy run inside a throw-away build clone of
#     the code tree (var/deploy/build), so the live generated/ and
#     pub/static/ are never removed first.
#   * Static content is deployed one (theme, locale) pair per process
#     through xargs -P, using every CPU core instead of Magento's own
#     --jobs implementation.
#   * The finished artifacts are swapped into place with directory
#     renames (milliseconds), the previous ones are kept until the
#     deployment has been verified.
#   * Maintenance mode is entered ONLY when setup:upgrade has to run,
#     and setup:upgrade runs ONLY when database changes are detected
#     (setup:db:status, plus a fingerprint of db_schema.xml, module.xml
#     and Setup/ files because setup:db:status ignores declarative
#     schema and data patches of modules without setup_version).
#
# Pipeline:
#   1. Preflight       validate config, PHP, composer, disk, memory, lock
#   2. Pre-deploy hook PRE_DEPLOY_CMD
#   3. Composer        composer install (live, plain autoloader)
#   4. Database check  setup:db:status, app:config:status, db fingerprint
#                      app:config:import runs here (live) when pending
#   5. Build           clone -> setup:di:compile -> dump-autoload -o
#                      -> parallel static deploy
#   6. Release         [maintenance] swap artifacts, setup:upgrade,
#                      cache:flush, OPcache reset [reopen]
#   7. Verify          health check, post-deployment checks, POST_DEPLOY_CMD
#
# On failure before the release phase the live site is untouched.
# On failure inside a maintenance window the window is left ENABLED and
# the previous artifacts are kept in var/deploy/previous.

set -uo pipefail

DEPLOY_VERSION="3.0.0"
readonly DEPLOY_VERSION

PLATFORM="$(uname -s)"
readonly PLATFORM

# ───────────────────────────────────────────────────────────────────
# Small utilities needed while loading configuration
# ───────────────────────────────────────────────────────────────────

# Strip leading/trailing whitespace
trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Split a comma/space separated list into the named array (bash 3.2 safe)
# Usage: split_list VAR_NAME "a, b c"
split_list() {
    local var="$1"
    local csv="${2//,/ }"
    local items=()
    local item
    # shellcheck disable=SC2206
    items=($csv)
    eval "$var=()"
    for item in ${items[@]+"${items[@]}"}; do
        item="$(trim "$item")"
        [[ -n "$item" ]] && eval "$var+=(\"\$item\")"
    done
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Config file support (.deploy.env)
# Priority: defaults < config file < environment < CLI flags
# ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
DEPLOY_CONFIG="${DEPLOY_CONFIG:-}"
_RUN_INIT=false

# Pre-scan CLI args for --config, --init, --dir (needed before config loading)
_pre_i=1
while (( _pre_i <= $# )); do
    case "${!_pre_i}" in
        --config)
            if (( _pre_i < $# )); then
                (( _pre_i++ ))
                DEPLOY_CONFIG="${!_pre_i}"
            fi
            ;;
        --init) _RUN_INIT=true ;;
        -d|--dir)
            if (( _pre_i < $# )); then
                (( _pre_i++ ))
                MAGENTO_DIR="${!_pre_i}"
            fi
            ;;
    esac
    (( _pre_i++ ))
done
unset _pre_i

# Resolve config file: explicit path > MAGENTO_DIR/.deploy.env > script dir > CWD
if [[ -z "$DEPLOY_CONFIG" ]]; then
    if [[ -n "${MAGENTO_DIR:-}" ]] && [[ -f "$MAGENTO_DIR/.deploy.env" ]]; then
        DEPLOY_CONFIG="$MAGENTO_DIR/.deploy.env"
    elif [[ -f "$SCRIPT_DIR/.deploy.env" ]]; then
        DEPLOY_CONFIG="$SCRIPT_DIR/.deploy.env"
    elif [[ -f ".deploy.env" ]]; then
        DEPLOY_CONFIG=".deploy.env"
    fi
fi

# KEY=VALUE parser. Only sets variables that are not already in the
# environment, so env vars and pre-scanned CLI flags keep priority.
_load_deploy_config() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line%%[[:space:]]\#*}"
        [[ -z "${line//[[:space:]]/}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z_0-9]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$value" in
                \"*\") value="${value#\"}"; value="${value%\"}" ;;
                \'*\') value="${value#\'}"; value="${value%\'}" ;;
            esac
            if [[ -z "${!key+x}" ]]; then
                printf -v "$key" '%s' "$value"
            fi
        fi
    done < "$file"
}

if [[ -n "$DEPLOY_CONFIG" ]] && [[ -f "$DEPLOY_CONFIG" ]]; then
    _load_deploy_config "$DEPLOY_CONFIG"
fi

# ───────────────────────────────────────────────────────────────────
# Defaults (config file / environment already applied above)
# ───────────────────────────────────────────────────────────────────
MAGENTO_DIR="${MAGENTO_DIR:-.}"
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:--1}"
BACKEND_THEME="${BACKEND_THEME:-Magento/backend}"
FRONTEND_LANGUAGES="${FRONTEND_LANGUAGES:-en_GB}"
BACKEND_LANGUAGES="${BACKEND_LANGUAGES:-en_US}"
MAINTENANCE="${MAINTENANCE:-auto}"
MAINTENANCE_ALLOWED_IPS="${MAINTENANCE_ALLOWED_IPS:-}"
DB_UPGRADE="${DB_UPGRADE:-auto}"
PARALLEL_JOBS="${PARALLEL_JOBS:-}"
SCD_EXTRA_ARGS="${SCD_EXTRA_ARGS:-}"
BUILD_DIR="${BUILD_DIR:-}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-}"
BUILD_ONLY="${BUILD_ONLY:-false}"
PUSH_TARGET="${PUSH_TARGET:-}"
PUSH_RUN="${PUSH_RUN:-false}"
KEEP_PREVIOUS="${KEEP_PREVIOUS:-false}"
SKIP_COMPOSER="${SKIP_COMPOSER:-false}"
SKIP_DB_CHECK="${SKIP_DB_CHECK:-false}"
SKIP_STATIC="${SKIP_STATIC:-false}"
SKIP_DI_COMPILE="${SKIP_DI_COMPILE:-false}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
NO_INTERACTION="${NO_INTERACTION:-false}"
LOG_FILE="${LOG_FILE:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
PRE_DEPLOY_CMD="${PRE_DEPLOY_CMD:-}"
POST_DEPLOY_CMD="${POST_DEPLOY_CMD:-}"
OPCACHE_RESET_CMD="${OPCACHE_RESET_CMD:-}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-3}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-30}"
DB_BACKUP="${DB_BACKUP:-false}"
DB_BACKUP_CMD="${DB_BACKUP_CMD:-}"
DEPLOY_ASCII="${DEPLOY_ASCII:-false}"

# FRONTEND_THEMES: comma-separated in config/env, bash array internally
if [[ -n "${FRONTEND_THEMES:-}" ]]; then
    split_list FRONTEND_THEMES "$FRONTEND_THEMES"
else
    FRONTEND_THEMES=("Magento/luma" "Magento/blank")
fi

# ───────────────────────────────────────────────────────────────────
# Terminal capabilities: colors and symbols
# ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then IS_TTY=true; else IS_TTY=false; fi

setup_terminal() {
    if [[ "$IS_TTY" == "true" && -z "${NO_COLOR:-}" ]]; then
        BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
        GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
        RED=$'\033[0;31m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
        BG_GREEN=$'\033[42;30m'; BG_RED=$'\033[41;97m'; BG_YELLOW=$'\033[43;30m'
    else
        BOLD="" DIM="" RESET="" GREEN="" YELLOW="" RED="" CYAN="" MAGENTA=""
        BG_GREEN="" BG_RED="" BG_YELLOW=""
    fi

    local charset="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ "$DEPLOY_ASCII" != "true" ]] && [[ "$charset" =~ [Uu][Tt][Ff]-?8 ]]; then
        SYM_OK="✔"; SYM_FAIL="✖"; SYM_WARN="⚠"; SYM_SKIP="–"; SYM_STEP="▸"
        SYM_ARROW="→"; SYM_DOT="·"; SYM_BAR="━"; SYM_PIPE="┃"; SYM_TIMES="×"; SYM_INFO="ℹ"
        SPINNER_FRAMES="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"
    else
        SYM_OK="+"; SYM_FAIL="x"; SYM_WARN="!"; SYM_SKIP="-"; SYM_STEP=">"
        SYM_ARROW="->"; SYM_DOT="."; SYM_BAR="="; SYM_PIPE="|"; SYM_TIMES="x"; SYM_INFO="i"
        SPINNER_FRAMES="| / - \\"
    fi
}
setup_terminal

# ───────────────────────────────────────────────────────────────────
# Internal state
# ───────────────────────────────────────────────────────────────────
DEPLOYMENT_START_TIME=0
DEPLOYMENT_STARTED=false
MAINTENANCE_ENABLED=false      # real state: maintenance:enable actually ran
MAINTENANCE_REQUESTED=false    # logical state: also true in --dry-run
MAINTENANCE_WINDOW_USED=false
MAINTENANCE_START=0
DOWNTIME_SECONDS=0
DB_UPGRADE_NEEDED=false
DB_UPGRADE_REASON=""
CONFIG_IMPORT_NEEDED=false
DB_FINGERPRINT=""
ARTIFACTS_SWAPPED=false
COMPOSER_RAN=false
BUILD_ROOT=""
PREVIOUS_DIR=""
DEPLOY_STATE_DIR=""
CURRENT_PHASE=""
CURRENT_STEP=""
LOCK_FILE=""
LOCK_METHOD=""
LOCK_FD=200
RETRY_DELAY=3
LAST_BACKUP_FILE=""
STEP_TIMINGS=()
WARNING_COUNT=0
CHILD_PID=""
SWAPPED_ITEMS=()
SCD_JOB_COUNT=0

# ───────────────────────────────────────────────────────────────────
# Cross-platform system helpers
# ───────────────────────────────────────────────────────────────────
get_cpu_cores() {
    case "$PLATFORM" in
        Darwin) sysctl -n hw.ncpu 2>/dev/null || echo 4 ;;
        *)      nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4 ;;
    esac
}

get_available_disk_gb() {
    case "$PLATFORM" in
        Darwin) df -P -g "$1" 2>/dev/null | awk 'NR==2 {print $4}' ;;
        *)      df -P -BG "$1" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' ;;
    esac
}

# Available memory in MB (macOS: free + inactive + speculative pages;
# the page size is read from the system, Apple Silicon uses 16K pages)
get_available_memory_mb() {
    case "$PLATFORM" in
        Darwin)
            local page_size
            page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
            vm_stat 2>/dev/null | awk -v ps="$page_size" '
                /Pages free|Pages inactive|Pages speculative/ { gsub(/\./, "", $NF); sum += $NF }
                END { if (sum > 0) printf "%d\n", sum * ps / 1048576; else print "N/A" }'
            ;;
        *)
            awk '/MemAvailable/ { printf "%d\n", $2 / 1024; found = 1; exit }
                 END { if (!found) print "N/A" }' /proc/meminfo 2>/dev/null || echo "N/A"
            ;;
    esac
}

get_total_memory_mb() {
    case "$PLATFORM" in
        Darwin)
            local bytes
            bytes="$(sysctl -n hw.memsize 2>/dev/null)"
            if [[ "$bytes" =~ ^[0-9]+$ ]]; then echo $(( bytes / 1048576 )); else echo "N/A"; fi
            ;;
        *)
            awk '/MemTotal/ { printf "%d\n", $2 / 1024; found = 1; exit }
                 END { if (!found) print "N/A" }' /proc/meminfo 2>/dev/null || echo "N/A"
            ;;
    esac
}

get_disk_usage_percent() {
    df -P -h "$1" 2>/dev/null | awk 'NR==2 {print $5}'
}

# Filesystem identifier of a path (rename-swaps and hardlinks need the
# build directory on the same filesystem as the live artifacts)
get_filesystem_id() {
    df -P "$1" 2>/dev/null | awk 'NR==2 {print $1}'
}

format_duration() {
    local seconds=$1
    local h=$(( seconds / 3600 ))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$(( seconds % 60 ))
    if (( h > 0 )); then
        printf '%dh %dm %ds' "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# Path relative to MAGENTO_DIR for display
rel_path() {
    local p="$1"
    if [[ -n "${MAGENTO_DIR:-}" && "$p" == "$MAGENTO_DIR/"* ]]; then
        printf '%s' "${p#"$MAGENTO_DIR/"}"
    else
        printf '%s' "$p"
    fi
}

# ───────────────────────────────────────────────────────────────────
# Logging and terminal UI
#   log LEVEL msg   - file log always, terminal for INFO/OK/WARN/ERROR
#   ui_phase title  - big phase header
#   ui_ok/ui_skip/ui_warn/ui_fail/ui_note - indented status lines
# ───────────────────────────────────────────────────────────────────
_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

_file_log() {
    [[ -n "$LOG_FILE" ]] && echo "[$(_timestamp)] $1: $2" >> "$LOG_FILE"
    return 0
}

log() {
    local level="$1"; shift
    local message="$*"
    _file_log "$level" "$message"
    case "$level" in
        INFO)  echo "  ${DIM}${message}${RESET}" ;;
        OK)    ui_ok "$message" ;;
        WARN)  ui_warn "$message" ;;
        ERROR) echo "  ${RED}${SYM_FAIL} ${message}${RESET}" >&2 ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo "  ${DIM}${SYM_DOT} ${message}${RESET}" ;;
    esac
    return 0
}

ui_phase() {
    CURRENT_PHASE="$1"
    local note="${2:-}"
    _file_log PHASE "$1${note:+ ($note)}"
    echo
    printf '%s%s %s%s' "$BOLD" "$SYM_STEP" "$1" "$RESET"
    [[ -n "$note" ]] && printf '  %s%s%s' "$DIM" "$note" "$RESET"
    echo
}

ui_ok()   { _file_log OK "$1";   echo "  ${GREEN}${SYM_OK}${RESET} $1${2:+  ${DIM}$2${RESET}}"; }
ui_skip() { _file_log SKIP "$1"; echo "  ${DIM}${SYM_SKIP} $1${2:+  $2}${RESET}"; }
ui_note() { _file_log INFO "$1"; echo "  ${DIM}  $1${RESET}"; }
ui_warn() { _file_log WARN "$1"; (( WARNING_COUNT++ )); echo "  ${YELLOW}${SYM_WARN} $1${RESET}"; }
ui_info() { _file_log INFO "$1"; echo "  ${CYAN}${SYM_INFO}${RESET} $1${2:+  ${DIM}$2${RESET}}"; }
ui_fail() { _file_log ERROR "$1"; echo "  ${RED}${SYM_FAIL} $1${RESET}" >&2; }
ui_dry()  { _file_log DRY "$1";  echo "  ${YELLOW}${SYM_SKIP} [dry run]${RESET} $1"; }

# Key/value line for the configuration overview
ui_kv() { printf '  %s%-15s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }

# Log an error and abort (cleanup trap handles lock release and reporting)
die() {
    ui_fail "$*"
    exit 1
}

record_step_time() { STEP_TIMINGS+=("$1|$2"); }

format_step_timings() {
    local timing name secs
    for timing in ${STEP_TIMINGS[@]+"${STEP_TIMINGS[@]}"}; do
        name="${timing%%|*}"
        secs="${timing##*|}"
        printf '  %-32s %s\n' "$name" "$(format_duration "$secs")"
    done
    return 0
}

count_log_lines() {
    local n=""
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        n="$(grep -c -- "$1" "$LOG_FILE" 2>/dev/null)" || true
    fi
    echo "${n:-0}"
}

# ───────────────────────────────────────────────────────────────────
# Lock (prevent concurrent deployments)
# flock where available (auto-released if the process dies), otherwise
# an atomic PID file with staleness detection (stock macOS).
# ───────────────────────────────────────────────────────────────────
acquire_lock() {
    LOCK_FILE="$MAGENTO_DIR/var/.deploy.lock"

    if [[ "$DRY_RUN" == "true" ]]; then
        log DEBUG "Dry run: skipping lock acquisition"
        return 0
    fi

    mkdir -p "$(dirname "$LOCK_FILE")"

    if command -v flock >/dev/null 2>&1; then
        eval "exec ${LOCK_FD}>\"\$LOCK_FILE\""
        if ! flock -n "$LOCK_FD"; then
            die "Another deployment is already running (lock: $LOCK_FILE)"
        fi
        LOCK_METHOD="flock"
        echo "$$" >&"$LOCK_FD"
    else
        if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
            local pid
            pid="$(cat "$LOCK_FILE" 2>/dev/null)"
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                die "Another deployment is already running (PID $pid, lock: $LOCK_FILE)"
            fi
            ui_warn "Removing stale deployment lock (PID ${pid:-unknown} is not running)"
            rm -f "$LOCK_FILE"
            if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
                die "Could not acquire deployment lock: $LOCK_FILE"
            fi
        fi
        LOCK_METHOD="pidfile"
    fi

    log DEBUG "Acquired deployment lock via $LOCK_METHOD (PID $$)"
}

release_lock() {
    [[ -z "$LOCK_FILE" ]] && return 0
    case "$LOCK_METHOD" in
        flock)
            # Close the FD (releases the kernel lock). The file is kept:
            # removing it would let two later runs lock different inodes.
            eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
            ;;
        pidfile)
            if [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
                rm -f "$LOCK_FILE"
            fi
            ;;
    esac
    LOCK_METHOD=""
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Cleanup on every exit path (failures, signals, normal exit)
# ───────────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    trap - EXIT

    # Stop whatever command is still running (spinner-wrapped or xargs)
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        pkill -P "$CHILD_PID" 2>/dev/null || true
        kill "$CHILD_PID" 2>/dev/null || true
    fi

    if (( exit_code != 0 )) && [[ "$DEPLOYMENT_STARTED" == "true" ]]; then
        [[ "$IS_TTY" == "true" ]] && printf '\r\033[K'
        echo
        case "$exit_code" in
            129|130|143) _file_log WARN "Deployment interrupted (exit code $exit_code)" ;;
            *)           _file_log ERROR "Deployment failed (exit code $exit_code)${CURRENT_STEP:+ during: $CURRENT_STEP}" ;;
        esac
        if [[ -n "$LOG_FILE" ]]; then
            generate_report "FAILED" $(( SECONDS - DEPLOYMENT_START_TIME ))
            display_summary "FAILED" $(( SECONDS - DEPLOYMENT_START_TIME )) "$exit_code"
        fi
    fi

    release_lock
    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ───────────────────────────────────────────────────────────────────
# Command wrappers
# ───────────────────────────────────────────────────────────────────

# bin/magento of the live installation (or of the build clone when a
# root is given as first argument via magento_cli_in)
magento_cli() {
    magento_cli_in "$MAGENTO_DIR" "$@"
}

magento_cli_in() {
    local root="$1"; shift
    if [[ -n "$PHP_MEMORY_LIMIT" ]]; then
        "$PHP_BIN" -d memory_limit="$PHP_MEMORY_LIMIT" "$root/bin/magento" "$@"
    else
        "$PHP_BIN" "$root/bin/magento" "$@"
    fi
}

composer_cli() {
    if [[ -n "$PHP_MEMORY_LIMIT" ]]; then
        "$PHP_BIN" -d memory_limit="$PHP_MEMORY_LIMIT" "$COMPOSER_BIN" "$@"
    else
        "$PHP_BIN" "$COMPOSER_BIN" "$@"
    fi
}

# Run a configured hook command string in the Magento directory
exec_hook_cmd() {
    ( cd "$MAGENTO_DIR" && eval "$1" )
}

get_current_mode() {
    if [[ -f "$MAGENTO_DIR/bin/magento" ]]; then
        magento_cli deploy:mode:show 2>/dev/null \
            | sed -n 's/.*Current application mode: \([a-z]*\).*/\1/p'
    fi
}

# Append captured command output to the log file
_log_output() {
    [[ -n "$LOG_FILE" ]] || return 0
    {
        echo "----- output: $1 (exit $2) -----"
        cat "$3"
        echo "----- end output -----"
    } >> "$LOG_FILE"
}

# Print the tail of a failed command's output
_show_failure_tail() {
    local file="$1" lines="${2:-20}"
    [[ -s "$file" ]] || return 0
    echo "  ${DIM}${SYM_PIPE} last $lines lines of output:${RESET}" >&2
    tail -n "$lines" "$file" | sed "s/^/  ${DIM}${SYM_PIPE}${RESET} /" >&2
    echo "  ${DIM}${SYM_PIPE} full output: $LOG_FILE${RESET}" >&2
}

# Wait for a background PID while animating a spinner (TTY) or staying
# quiet (non-TTY). Optional $3 = callback printing extra progress text.
_wait_with_spinner() {
    local pid="$1" label="$2" progress_fn="${3:-}"
    local start=$SECONDS frame=0 extra=""
    local frames=()
    # shellcheck disable=SC2206
    frames=($SPINNER_FRAMES)
    local nframes=${#frames[@]}

    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$IS_TTY" == "true" ]]; then
            [[ -n "$progress_fn" ]] && extra="$("$progress_fn")"
            printf '\r\033[K  %s%s%s %s  %s%s%s' "$CYAN" "${frames[$(( frame % nframes ))]}" "$RESET" \
                "$label" "$DIM" "${extra:+$extra $SYM_DOT }$(format_duration $(( SECONDS - start )))" "$RESET"
            (( frame++ ))
        elif [[ -n "$progress_fn" ]]; then
            "$progress_fn" >/dev/null
        fi
        sleep 0.5
    done
    [[ "$IS_TTY" == "true" ]] && printf '\r\033[K'
    return 0
}

# Run a command with logging, spinner and optional retry.
# Usage: run_cmd [--retries N] [--show-output] [--label "desc"] -- command args...
run_cmd() {
    local retries=1 show_output=false label=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --retries)     retries="$2"; shift 2 ;;
            --show-output) show_output=true; shift ;;
            --label)       label="$2"; shift 2 ;;
            --)            shift; break ;;
            *)             break ;;
        esac
    done

    local cmd=("$@")
    [[ -z "$label" ]] && label="${cmd[*]}"
    CURRENT_STEP="$label"
    log DEBUG "Executing: ${cmd[*]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "$label"
        return 0
    fi

    local attempt=0 result=1 start tmp_out
    tmp_out="$(mktemp)" || die "Failed to create temporary file"

    while (( attempt < retries )); do
        (( attempt++ ))
        start=$SECONDS
        if (( retries > 1 && attempt > 1 )); then
            ui_note "$label (attempt $attempt/$retries)"
        fi

        if [[ "$show_output" == "true" || "$VERBOSE" == "true" ]]; then
            echo "  ${CYAN}${SYM_STEP}${RESET} $label"
            if "${cmd[@]}" 2>&1 | tee "$tmp_out" | sed 's/^/    /'; then
                result=${PIPESTATUS[0]}
            else
                result=${PIPESTATUS[0]}
            fi
        else
            if [[ "$IS_TTY" != "true" ]]; then
                echo "  ${SYM_STEP} $label..."
            fi
            "${cmd[@]}" > "$tmp_out" 2>&1 &
            CHILD_PID=$!
            _wait_with_spinner "$CHILD_PID" "$label"
            wait "$CHILD_PID"
            result=$?
            CHILD_PID=""
        fi

        _log_output "$label (attempt $attempt)" "$result" "$tmp_out"

        if (( result == 0 )); then
            ui_ok "$label" "$(format_duration $(( SECONDS - start )))"
            rm -f "$tmp_out"
            return 0
        fi

        ui_fail "$label (exit $result after $(format_duration $(( SECONDS - start ))))"
        if (( attempt < retries )); then
            ui_warn "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
    done

    if [[ "$show_output" != "true" && "$VERBOSE" != "true" ]]; then
        _show_failure_tail "$tmp_out" 20
    fi
    rm -f "$tmp_out"
    return "$result"
}

# ───────────────────────────────────────────────────────────────────
# Help
# ───────────────────────────────────────────────────────────────────
display_help() {
    cat << 'HELP'
Magento 2 zero-downtime deployment

USAGE:
    deploy.sh [OPTIONS]

PIPELINE:
    1. Preflight        validate config, PHP, composer, disk, memory, lock
    2. Pre-deploy hook  PRE_DEPLOY_CMD (abort on failure)
    3. Composer         composer install (site live, plain autoloader)
    4. Database check   setup:db:status + app:config:status + a fingerprint
                        of db_schema.xml / module.xml / Setup files.
                        app:config:import runs here (live) when pending.
    5. Build            code tree is cloned into var/deploy/build, then
                        setup:di:compile, composer dump-autoload -o (the
                        classmap must match the new generated code) and
                        setup:static-content:deploy run there - one (theme,
                        locale) process per CPU core - while the site keeps
                        serving the old assets
    6. Release          artifacts are swapped into place with directory
                        renames; setup:upgrade runs ONLY when database
                        changes were detected and ONLY then maintenance
                        mode is enabled; cache:flush; OPcache reset
    7. Verify           health check, post-deployment checks, POST_DEPLOY_CMD

OPTIONS:
    -h, --help              Show this help message
    --init                  Generate .deploy.env by reading the Magento DB
    --config FILE           Use a specific config file (default: .deploy.env)
    -d, --dir PATH          Magento installation directory (default: .)
    -p, --php PATH          PHP binary (default: php)
    -c, --composer PATH     Composer binary (default: composer)
    -j, --jobs NUM          Parallel static-content processes (default: CPU cores)
    --db-upgrade MODE       auto (default), always, never - see DATABASE
    --maintenance MODE      auto (default), always, never - see MAINTENANCE
    --memory-limit LIMIT    PHP memory_limit for CLI commands (default: -1)
    --skip-composer         Skip composer install
    --skip-db-check         Skip database/config checks and setup:upgrade
    --skip-static           Keep current static content
    --skip-di-compile       Keep current generated code
    --keep-previous         Keep the replaced artifacts in var/deploy/previous
    --build-only            Stop after the build phase: artifacts stay in
                            var/deploy/build (generated/, pub/static/) for a
                            pipeline deployment on another host
    --artifacts DIR         Skip the build and release the pre-built
                            generated/ and pub/static/ found in DIR
    --push user@host:DIR    Implies --build-only; rsync the artifacts over
                            SSH into DIR/var/deploy/incoming on the server
    --push-run              After --push, run 'deploy.sh --artifacts' there
    --dry-run               Show what would be executed without running
    --no-interaction        Never prompt (prompts use their default answer)
    --ascii                 Plain ASCII output (no unicode symbols)
    -v, --verbose           Stream command output, show debug messages
    --log FILE              Log file (default: var/log/deploy_TIMESTAMP.log)
    --log-retention DAYS    Delete deploy logs/reports/backups older than N days
                            (0 disables, default: 30)
    --frontend-themes T     Comma-separated frontend themes
    --backend-theme T       Backend theme (default: Magento/backend)
    --frontend-langs L      Frontend locales, space/comma separated (default: en_GB)
    --backend-langs L       Backend locales, space/comma separated (default: en_US)

DATABASE (DB_UPGRADE):
    auto    setup:upgrade runs when setup:db:status reports pending changes
            OR the database fingerprint changed since the last successful
            upgrade (db_schema.xml, db_schema_whitelist.json, module.xml,
            Setup/ files, app/etc/config.php). Without a stored fingerprint
            (first run) the upgrade runs once to establish the baseline.
    always  Always run setup:upgrade.
    never   Never run setup:upgrade (fingerprint is not updated).

MAINTENANCE:
    auto    Enter maintenance mode only while setup:upgrade runs. Everything
            else (composer, compile, static content, swap, cache flush) is
            done with the site online.
    always  Keep the site in maintenance mode for the whole release phase
            (swap, upgrade, cache flush, OPcache reset).
    never   Never touch maintenance mode, even for setup:upgrade (dangerous).
    MAINTENANCE_ALLOWED_IPS (comma/space separated) whitelists IPs.
    On failure inside a window the script leaves maintenance mode ENABLED
    and prints how to recover - a broken site should not reopen blindly.

HOOKS AND CHECKS (set in .deploy.env or the environment):
    PRE_DEPLOY_CMD      Runs after the lock is taken, before any change.
    POST_DEPLOY_CMD     Runs at the end of a successful deployment.
    OPCACHE_RESET_CMD   Runs right after the artifact swap, e.g.
                        'cachetool opcache:reset --fcgi=/run/php-fpm.sock'
                        or 'sudo systemctl reload php8.3-fpm'. REQUIRED on
                        hosts with opcache.validate_timestamps=0.
    HEALTHCHECK_URL     curl'ed after the release; anything but HTTP 2xx
                        (after HEALTHCHECK_RETRIES x HEALTHCHECK_TIMEOUT)
                        fails the deployment.
    DB_BACKUP=true      gzipped mysqldump into var/backups/ before
                        setup:upgrade (credentials from env.php).
    DB_BACKUP_CMD       Custom backup command used instead of mysqldump.
    SCD_EXTRA_ARGS      Extra options for every setup:static-content:deploy
                        process (e.g. '--no-js-bundle --strategy=quick').
    BUILD_DIR           Build/previous directory (default: var/deploy).
    ARTIFACTS_DIR       Pre-built artifacts to release (same as --artifacts).
                        Build them with --build-only on the same commit,
                        composer.lock and app/etc/config.php, then rsync
                        var/deploy/build/{generated,pub,vendor/composer,
                        vendor/autoload.php} to the server (or use --push).
    All hook commands run with the Magento directory as working directory.

CONFIG FILE:
    .deploy.env is loaded from (in order): --config, MAGENTO_DIR, the
    script directory, the current directory.
    Priority: CLI flags > environment > config file > defaults.
    'deploy.sh --init' generates one interactively.

ENVIRONMENT VARIABLES:
    DEPLOY_CONFIG, MAGENTO_DIR, PHP_BIN, COMPOSER_BIN, PHP_MEMORY_LIMIT,
    PARALLEL_JOBS, FRONTEND_THEMES, BACKEND_THEME, FRONTEND_LANGUAGES,
    BACKEND_LANGUAGES, DB_UPGRADE, MAINTENANCE, MAINTENANCE_ALLOWED_IPS,
    SCD_EXTRA_ARGS, BUILD_DIR, ARTIFACTS_DIR, BUILD_ONLY, KEEP_PREVIOUS, SKIP_COMPOSER, SKIP_DB_CHECK,
    SKIP_STATIC, SKIP_DI_COMPILE, VERBOSE, DRY_RUN, NO_INTERACTION,
    DEPLOY_ASCII, NO_COLOR, LOG_FILE, LOG_RETENTION_DAYS, PRE_DEPLOY_CMD,
    POST_DEPLOY_CMD, OPCACHE_RESET_CMD, HEALTHCHECK_URL,
    HEALTHCHECK_RETRIES, HEALTHCHECK_TIMEOUT, DB_BACKUP, DB_BACKUP_CMD

EXAMPLES:
    deploy.sh --init                          # Generate .deploy.env
    deploy.sh                                 # Full zero-downtime deploy
    deploy.sh --dry-run                       # Preview
    deploy.sh -j 16 -v                        # 16 static-content processes, verbose
    deploy.sh --skip-static --skip-di-compile # Code-only deploy
    deploy.sh --db-upgrade always             # Force setup:upgrade
    deploy.sh --build-only                    # Build artifacts here ...
    deploy.sh --artifacts /srv/build          # ... release them on the server
    deploy.sh --push www@shop:/var/www/html --push-run   # build here, release there
HELP
}

# ───────────────────────────────────────────────────────────────────
# Argument parsing
# ───────────────────────────────────────────────────────────────────
_require_value() {
    if (( $2 < 2 )); then
        echo "Option $1 requires a value" >&2
        echo "Run '$0 --help' for usage." >&2
        exit 1
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)          display_help; exit 0 ;;
            --init)             _RUN_INIT=true; shift ;;
            --config)           _require_value "$1" $#; shift 2 ;;  # consumed in pre-scan
            -d|--dir)           _require_value "$1" $#; MAGENTO_DIR="$2"; shift 2 ;;
            -p|--php)           _require_value "$1" $#; PHP_BIN="$2"; shift 2 ;;
            -c|--composer)      _require_value "$1" $#; COMPOSER_BIN="$2"; shift 2 ;;
            -j|--jobs)          _require_value "$1" $#; PARALLEL_JOBS="$2"; shift 2 ;;
            --db-upgrade)       _require_value "$1" $#; DB_UPGRADE="$2"; shift 2 ;;
            --maintenance)      _require_value "$1" $#; MAINTENANCE="$2"; shift 2 ;;
            --memory-limit)     _require_value "$1" $#; PHP_MEMORY_LIMIT="$2"; shift 2 ;;
            --skip-composer)    SKIP_COMPOSER=true; shift ;;
            --skip-db-check)    SKIP_DB_CHECK=true; shift ;;
            --skip-static)      SKIP_STATIC=true; shift ;;
            --skip-di-compile)  SKIP_DI_COMPILE=true; shift ;;
            --keep-previous)    KEEP_PREVIOUS=true; shift ;;
            --build-only)       BUILD_ONLY=true; shift ;;
            --artifacts)        _require_value "$1" $#; ARTIFACTS_DIR="$2"; shift 2 ;;
            --push)             _require_value "$1" $#; PUSH_TARGET="$2"; BUILD_ONLY=true; shift 2 ;;
            --push-run)         PUSH_RUN=true; shift ;;
            --dry-run)          DRY_RUN=true; shift ;;
            --no-interaction)   NO_INTERACTION=true; shift ;;
            --ascii)            DEPLOY_ASCII=true; setup_terminal; shift ;;
            -v|--verbose)       VERBOSE=true; shift ;;
            --log)              _require_value "$1" $#; LOG_FILE="$2"; shift 2 ;;
            --log-retention)    _require_value "$1" $#; LOG_RETENTION_DAYS="$2"; shift 2 ;;
            --frontend-themes)  _require_value "$1" $#; split_list FRONTEND_THEMES "$2"; shift 2 ;;
            --backend-theme)    _require_value "$1" $#; BACKEND_THEME="$2"; shift 2 ;;
            --frontend-langs)   _require_value "$1" $#; FRONTEND_LANGUAGES="$2"; shift 2 ;;
            --backend-langs)    _require_value "$1" $#; BACKEND_LANGUAGES="$2"; shift 2 ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Run '$0 --help' for usage." >&2
                exit 1
                ;;
        esac
    done
}

# Confirm prompt; non-interactive runs (flag or no TTY) use the default
confirm() {
    local message="$1" default="${2:-n}"
    if [[ "$NO_INTERACTION" == "true" ]] || [[ ! -t 0 ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    local prompt="[y/N]"
    [[ "$default" == "y" ]] && prompt="[Y/n]"
    local answer=""
    printf '%s%s %s %s' "$YELLOW" "$message" "$prompt" "$RESET"
    read -r answer || true
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Preflight
# ───────────────────────────────────────────────────────────────────

# Resolve composer to an absolute path: it is invoked via "$PHP_BIN"
# "$COMPOSER_BIN", and PHP needs a real file, not a command name.
resolve_composer_bin() {
    local resolved
    if [[ -f "$COMPOSER_BIN" ]]; then
        COMPOSER_BIN="$(cd "$(dirname "$COMPOSER_BIN")" && pwd)/$(basename "$COMPOSER_BIN")"
        return 0
    fi
    if resolved="$(command -v "$COMPOSER_BIN" 2>/dev/null)"; then
        COMPOSER_BIN="$resolved"; return 0
    fi
    if [[ -f "$MAGENTO_DIR/$COMPOSER_BIN" ]]; then
        COMPOSER_BIN="$(cd "$MAGENTO_DIR" && pwd)/$(basename "$COMPOSER_BIN")"; return 0
    fi
    if [[ -f "$MAGENTO_DIR/composer.phar" ]]; then
        COMPOSER_BIN="$(cd "$MAGENTO_DIR" && pwd)/composer.phar"; return 0
    fi
    if resolved="$(command -v composer 2>/dev/null)"; then
        COMPOSER_BIN="$resolved"; return 0
    fi
    return 1
}

validate_configuration() {
    local errors=0 file

    if [[ -d "$MAGENTO_DIR" ]]; then
        MAGENTO_DIR="$(cd "$MAGENTO_DIR" && pwd)"
    else
        ui_fail "Magento directory not found: $MAGENTO_DIR"
        (( errors++ ))
    fi

    for file in app/etc/env.php bin/magento composer.json; do
        if [[ ! -f "$MAGENTO_DIR/$file" ]]; then
            ui_fail "Required file missing: $MAGENTO_DIR/$file"
            (( errors++ ))
        fi
    done

    if [[ -f "$MAGENTO_DIR/bin/magento" && ! -x "$MAGENTO_DIR/bin/magento" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            ui_warn "bin/magento is not executable (dry run: not fixing)"
        else
            ui_warn "bin/magento is not executable, fixing permissions"
            chmod +x "$MAGENTO_DIR/bin/magento"
        fi
    fi

    if (( EUID == 0 )); then
        ui_warn "Running as root: deployed files will be root-owned and may break the web server user"
    fi

    if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
        ui_fail "PHP binary not found: $PHP_BIN"
        (( errors++ ))
    else
        local php_version php_modules ext
        php_version="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")"
        php_modules="$("$PHP_BIN" -m 2>/dev/null)"

        local missing_ext=()
        for ext in bcmath ctype curl dom gd iconv intl mbstring openssl pdo_mysql simplexml soap xsl zip sockets; do
            grep -qi "^${ext}$" <<< "$php_modules" || missing_ext+=("$ext")
        done
        if (( ${#missing_ext[@]} > 0 )); then
            ui_fail "PHP $php_version is missing extensions: ${missing_ext[*]}"
            (( errors++ ))
        else
            ui_ok "PHP $php_version with all required extensions"
        fi
        # "Zend OPcache" lists itself with a prefix, hence substring match
        for ext in redis apcu opcache; do
            grep -qi "$ext" <<< "$php_modules" || ui_warn "Recommended PHP extension missing: $ext"
        done
    fi

    if ! resolve_composer_bin; then
        ui_fail "Composer binary not found: $COMPOSER_BIN"
        (( errors++ ))
    else
        local composer_ver
        composer_ver="$(composer_cli --version 2>/dev/null | head -1)"
        ui_ok "${composer_ver:-Composer} ($(rel_path "$COMPOSER_BIN"))"
    fi

    if [[ -n "$PARALLEL_JOBS" ]] && { ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || (( PARALLEL_JOBS < 1 )); }; then
        ui_warn "Invalid PARALLEL_JOBS '$PARALLEL_JOBS', using CPU core count"
        PARALLEL_JOBS=""
    fi
    if ! [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        ui_warn "Invalid LOG_RETENTION_DAYS '$LOG_RETENTION_DAYS', defaulting to 30"
        LOG_RETENTION_DAYS=30
    fi
    case "$MAINTENANCE" in
        auto|always|never) ;;
        *) ui_warn "Invalid MAINTENANCE '$MAINTENANCE' (auto/always/never), using auto"; MAINTENANCE=auto ;;
    esac
    case "$DB_UPGRADE" in
        auto|always|never) ;;
        *) ui_warn "Invalid DB_UPGRADE '$DB_UPGRADE' (auto/always/never), using auto"; DB_UPGRADE=auto ;;
    esac
    if ! [[ "$HEALTHCHECK_RETRIES" =~ ^[0-9]+$ ]] || (( HEALTHCHECK_RETRIES < 1 )); then
        ui_warn "Invalid HEALTHCHECK_RETRIES '$HEALTHCHECK_RETRIES', defaulting to 3"
        HEALTHCHECK_RETRIES=3
    fi
    if ! [[ "$HEALTHCHECK_TIMEOUT" =~ ^[0-9]+$ ]] || (( HEALTHCHECK_TIMEOUT < 1 )); then
        ui_warn "Invalid HEALTHCHECK_TIMEOUT '$HEALTHCHECK_TIMEOUT', defaulting to 30"
        HEALTHCHECK_TIMEOUT=30
    fi
    if [[ -n "$HEALTHCHECK_URL" ]] && ! command -v curl >/dev/null 2>&1; then
        ui_warn "HEALTHCHECK_URL is set but curl is not available - health check will be skipped"
    fi
    if [[ "$DB_BACKUP" == "true" && -z "$DB_BACKUP_CMD" ]] && ! command -v mysqldump >/dev/null 2>&1; then
        ui_fail "DB_BACKUP=true but mysqldump was not found (install a MySQL client or set DB_BACKUP_CMD)"
        (( errors++ ))
    fi
    if (( ${#FRONTEND_THEMES[@]} == 0 )); then
        ui_warn "No frontend themes configured - frontend static content will be skipped"
    fi
    if [[ -n "$ARTIFACTS_DIR" ]]; then
        if [[ "$BUILD_ONLY" == "true" ]]; then
            ui_fail "--artifacts and --build-only cannot be combined"
            (( errors++ ))
        elif [[ ! -d "$ARTIFACTS_DIR" ]]; then
            ui_fail "Artifacts directory not found: $ARTIFACTS_DIR"
            (( errors++ ))
        else
            ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd)"
            if [[ "$SKIP_DI_COMPILE" != "true" && ! -d "$ARTIFACTS_DIR/generated/code" ]]; then
                ui_fail "Artifacts directory has no generated/code (use --skip-di-compile to keep the current one)"
                (( errors++ ))
            fi
            if [[ "$SKIP_STATIC" != "true" && ! -f "$ARTIFACTS_DIR/pub/static/deployed_version.txt" ]]; then
                ui_fail "Artifacts directory has no pub/static/deployed_version.txt (use --skip-static to keep the current one)"
                (( errors++ ))
            fi
        fi
    fi
    if [[ "$SKIP_STATIC" != "true" && -z "$ARTIFACTS_DIR" ]] && ! command -v xargs >/dev/null 2>&1; then
        ui_fail "xargs is required for parallel static content deployment"
        (( errors++ ))
    fi

    # Build directory (same filesystem as the live artifacts is required
    # for hardlink clones and rename swaps)
    BUILD_DIR="${BUILD_DIR:-$MAGENTO_DIR/var/deploy}"
    [[ "$BUILD_DIR" != /* ]] && BUILD_DIR="$MAGENTO_DIR/$BUILD_DIR"
    DEPLOY_STATE_DIR="$BUILD_DIR"
    BUILD_ROOT="$BUILD_DIR/build"
    PREVIOUS_DIR="$BUILD_DIR/previous"
    if [[ -d "$MAGENTO_DIR" && -d "$MAGENTO_DIR/pub" ]]; then
        mkdir -p "$BUILD_DIR" 2>/dev/null || true
        local fs_build fs_pub
        fs_build="$(get_filesystem_id "$BUILD_DIR")"
        fs_pub="$(get_filesystem_id "$MAGENTO_DIR/pub")"
        if [[ -n "$fs_build" && -n "$fs_pub" && "$fs_build" != "$fs_pub" ]]; then
            ui_fail "BUILD_DIR ($BUILD_DIR) is on a different filesystem than $MAGENTO_DIR/pub - artifact swaps need the same filesystem"
            (( errors++ ))
        fi
    fi

    if (( errors > 0 )); then
        ui_fail "Configuration validation found $errors error(s)"
        if ! confirm "Continue despite validation errors?" n; then
            die "Deployment aborted (validation failed)"
        fi
        ui_warn "Continuing despite validation errors"
    fi
}

check_system_requirements() {
    local disk_gb mem_available mem_total cpu_cores
    disk_gb="$(get_available_disk_gb "$MAGENTO_DIR")"
    mem_available="$(get_available_memory_mb)"
    mem_total="$(get_total_memory_mb)"
    cpu_cores="$(get_cpu_cores)"
    [[ "$cpu_cores" =~ ^[0-9]+$ ]] || cpu_cores=4

    if [[ -z "$PARALLEL_JOBS" ]]; then
        PARALLEL_JOBS="$cpu_cores"
    elif (( PARALLEL_JOBS > cpu_cores )); then
        ui_warn "Reducing parallel jobs from $PARALLEL_JOBS to $cpu_cores (CPU cores)"
        PARALLEL_JOBS="$cpu_cores"
    fi

    local summary="$cpu_cores cores"
    if [[ "$mem_available" =~ ^[0-9]+$ ]]; then
        summary="$summary, ${mem_available} MB free of ${mem_total} MB"
        if (( mem_available < 2048 )); then
            ui_warn "Low memory: ${mem_available} MB available (recommend 2 GB+)"
        fi
        # Each static-content process needs roughly 700 MB
        if [[ "$SKIP_STATIC" != "true" ]] && (( PARALLEL_JOBS * 700 > mem_available )); then
            ui_warn "$PARALLEL_JOBS parallel static-content processes may need ~$(( PARALLEL_JOBS * 700 )) MB; only ${mem_available} MB available (use -j to lower)"
        fi
    fi
    if [[ "$disk_gb" =~ ^[0-9]+$ ]]; then
        summary="$summary, ${disk_gb} GB disk free"
        if (( disk_gb < 5 )); then
            ui_warn "Low disk space: ${disk_gb} GB available (the build keeps old and new artifacts side by side)"
        fi
    fi
    ui_ok "System: $summary"
}

preflight() {
    ui_phase "Preflight"
    local start=$SECONDS
    validate_configuration
    check_system_requirements
    acquire_lock
    record_step_time "Preflight" $(( SECONDS - start ))
}

# ───────────────────────────────────────────────────────────────────
# Hooks, OPcache reset, health check, DB backup
# ───────────────────────────────────────────────────────────────────
run_pre_deploy_hook() {
    [[ -z "$PRE_DEPLOY_CMD" ]] && return 0
    ui_phase "Pre-deploy hook"
    local start=$SECONDS
    if ! run_cmd --show-output --label "pre-deploy: $PRE_DEPLOY_CMD" -- exec_hook_cmd "$PRE_DEPLOY_CMD"; then
        die "Pre-deploy hook failed"
    fi
    record_step_time "Pre-deploy hook" $(( SECONDS - start ))
}

run_post_deploy_hook() {
    [[ -z "$POST_DEPLOY_CMD" ]] && return 0
    ui_phase "Post-deploy hook"
    local start=$SECONDS
    # The deployment itself already succeeded - a failing hook only warns
    if ! run_cmd --show-output --label "post-deploy: $POST_DEPLOY_CMD" -- exec_hook_cmd "$POST_DEPLOY_CMD"; then
        ui_warn "Post-deploy hook failed (deployment itself succeeded)"
    fi
    record_step_time "Post-deploy hook" $(( SECONDS - start ))
}

# With opcache.validate_timestamps=0 php-fpm keeps serving the old
# generated code until OPcache is reset or php-fpm is reloaded.
opcache_reset() {
    if [[ -z "$OPCACHE_RESET_CMD" ]]; then
        ui_skip "OPcache reset" "(OPCACHE_RESET_CMD not set - reload php-fpm manually if opcache.validate_timestamps=0)"
        return 0
    fi
    local start=$SECONDS
    if ! run_cmd --show-output --label "opcache reset: $OPCACHE_RESET_CMD" -- exec_hook_cmd "$OPCACHE_RESET_CMD"; then
        ui_warn "OPcache reset failed - php-fpm may serve stale code until it is reloaded"
    fi
    record_step_time "OPcache reset" $(( SECONDS - start ))
}

health_check() {
    [[ -z "$HEALTHCHECK_URL" ]] && return 0
    CURRENT_STEP="Health check"
    local start=$SECONDS

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would check $HEALTHCHECK_URL (expect HTTP 2xx)"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        ui_warn "curl not available - skipping health check"
        return 0
    fi

    local attempt=0 http_code=""
    while (( attempt < HEALTHCHECK_RETRIES )); do
        (( attempt++ ))
        http_code="$(curl -sS -L --max-redirs 5 -o /dev/null -w '%{http_code}' \
            --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" 2>>"$LOG_FILE")" || true
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            ui_ok "Health check: $HEALTHCHECK_URL $SYM_ARROW HTTP $http_code" "(attempt $attempt, $(format_duration $(( SECONDS - start ))))"
            record_step_time "Health check" $(( SECONDS - start ))
            return 0
        fi
        ui_warn "Health check attempt $attempt/$HEALTHCHECK_RETRIES: HTTP ${http_code:-no response}"
        (( attempt < HEALTHCHECK_RETRIES )) && sleep "$RETRY_DELAY"
    done

    record_step_time "Health check" $(( SECONDS - start ))
    die "Health check failed: $HEALTHCHECK_URL returned HTTP ${http_code:-none} after $HEALTHCHECK_RETRIES attempts (site is OPEN but unhealthy)"
}

backup_database() {
    if [[ "$DB_BACKUP" != "true" && -z "$DB_BACKUP_CMD" ]]; then
        return 0
    fi
    local start=$SECONDS

    if [[ -n "$DB_BACKUP_CMD" ]]; then
        if ! run_cmd --show-output --label "db backup: $DB_BACKUP_CMD" -- exec_hook_cmd "$DB_BACKUP_CMD"; then
            die "Database backup command failed"
        fi
        LAST_BACKUP_FILE="(custom command)"
        record_step_time "Database backup" $(( SECONDS - start ))
        return 0
    fi

    CURRENT_STEP="Database backup"
    local backup_dir="$MAGENTO_DIR/var/backups"
    local backup_file
    backup_file="$backup_dir/deploy_db_$(date +%Y%m%d_%H%M%S).sql.gz"

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would dump database to $(rel_path "$backup_file")"
        return 0
    fi

    local db_info
    db_info="$("$PHP_BIN" -r '
        $env = @include $argv[1] . "/app/etc/env.php";
        if (!is_array($env)) { exit(1); }
        $db = isset($env["db"]["connection"]["default"]) ? $env["db"]["connection"]["default"] : array();
        foreach (array("host", "port", "dbname", "username", "password") as $key) {
            echo (isset($db[$key]) ? $db[$key] : "") . PHP_EOL;
        }
    ' "$MAGENTO_DIR" 2>/dev/null)" || die "Could not read database credentials from app/etc/env.php"

    local db_host db_port db_name db_user db_pass
    {
        IFS= read -r db_host
        IFS= read -r db_port
        IFS= read -r db_name
        IFS= read -r db_user
        IFS= read -r db_pass
    } <<< "$db_info"
    [[ -n "$db_host" && -n "$db_name" ]] || die "Incomplete database credentials in app/etc/env.php"

    if [[ -z "$db_port" && "$db_host" == *:* ]]; then
        db_port="${db_host##*:}"
        db_host="${db_host%%:*}"
    fi

    mkdir -p "$backup_dir"
    local dump_args=(-h "$db_host")
    [[ -n "$db_port" ]] && dump_args+=(-P "$db_port")
    dump_args+=(-u "$db_user" --single-transaction --quick --no-tablespaces "$db_name")

    if [[ "$IS_TTY" != "true" ]]; then echo "  ${SYM_STEP} Dumping database '$db_name'..."; fi
    ( MYSQL_PWD="$db_pass" mysqldump "${dump_args[@]}" 2>>"$LOG_FILE" | gzip > "$backup_file" ) &
    CHILD_PID=$!
    _wait_with_spinner "$CHILD_PID" "Dumping database '$db_name'"
    if ! wait "$CHILD_PID"; then
        CHILD_PID=""
        rm -f "$backup_file"
        die "Database backup failed (mysqldump error - see $LOG_FILE)"
    fi
    CHILD_PID=""
    if [[ ! -s "$backup_file" ]]; then
        rm -f "$backup_file"
        die "Database backup produced an empty file"
    fi

    LAST_BACKUP_FILE="$backup_file"
    ui_ok "Database backup: $(rel_path "$backup_file") ($(du -h "$backup_file" | cut -f1 | tr -d ' '))" "$(format_duration $(( SECONDS - start )))"
    record_step_time "Database backup" $(( SECONDS - start ))
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Composer (site live)
# ───────────────────────────────────────────────────────────────────
composer_phase() {
    ui_phase "Composer" "site live"
    local start=$SECONDS

    if [[ "$SKIP_COMPOSER" == "true" ]]; then
        ui_skip "composer install" "(--skip-composer)"
    else
        if [[ ! -f "$MAGENTO_DIR/composer.lock" ]]; then
            die "composer.lock not found in $MAGENTO_DIR - deployments must install from a lock file"
        fi
        COMPOSER_RAN=true
        if ! run_cmd --label "composer install --no-dev" -- \
            composer_cli install --no-dev --no-interaction --no-progress --prefer-dist --working-dir="$MAGENTO_DIR"; then
            die "Composer install failed"
        fi
    fi

    # The optimized classmap is generated in the build clone after
    # setup:di:compile (see dump_autoload_in_build): an optimized dump made
    # here would hard-code generated/ files that the build replaces.
    record_step_time "Composer" $(( SECONDS - start ))
}

# Magento deletes generated/ and var/cache on its next bootstrap when
# var/.regenerate exists (module:enable/disable leave it behind). On a
# production site that means a fatal error window, and an optimized
# classmap would then point at missing files. The deployment rebuilds
# the generated code anyway, so the flag is dropped first.
clear_regenerate_flag() {
    local flag="$MAGENTO_DIR/var/.regenerate"
    [[ -e "$flag" ]] || return 0
    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would remove var/.regenerate (Magento would otherwise wipe generated/ on the next bin/magento call)"
        return 0
    fi
    rm -f "$flag" "$MAGENTO_DIR/var/.regenerate.lock"
    if [[ "$SKIP_DI_COMPILE" == "true" ]]; then
        ui_warn "Removed var/.regenerate: Magento wanted generated/ rebuilt but --skip-di-compile keeps it - run without --skip-di-compile soon"
    else
        ui_info "Removed var/.regenerate (generated code is rebuilt by this deployment instead of wiped live)"
    fi
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Database check
# setup:db:status only compares module setup_version values, so new
# declarative schema or data patches in existing modules go unnoticed.
# A fingerprint of the schema/patch related files closes that gap.
# ───────────────────────────────────────────────────────────────────
compute_db_fingerprint() {
    local dirs=() d
    for d in app/code vendor; do
        [[ -d "$MAGENTO_DIR/$d" ]] && dirs+=("$d")
    done
    {
        if (( ${#dirs[@]} > 0 )); then
            ( cd "$MAGENTO_DIR" && find "${dirs[@]}" -type f \
                \( -name db_schema.xml -o -name db_schema_whitelist.json -o -name module.xml -o -path '*/Setup/*.php' \) \
                -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null )
        fi
        [[ -f "$MAGENTO_DIR/app/etc/config.php" ]] && ( cd "$MAGENTO_DIR" && cksum app/etc/config.php )
    } | cksum | awk '{print $1}'
}

save_db_fingerprint() {
    [[ -n "$DB_FINGERPRINT" && "$DRY_RUN" != "true" ]] || return 0
    mkdir -p "$DEPLOY_STATE_DIR"
    printf '%s\n' "$DB_FINGERPRINT" > "$DEPLOY_STATE_DIR/db-fingerprint"
}

database_check_phase() {
    ui_phase "Database check"
    local start=$SECONDS

    clear_regenerate_flag

    if [[ "$SKIP_DB_CHECK" == "true" ]]; then
        ui_skip "setup:db:status / app:config:status / setup:upgrade" "(--skip-db-check)"
        record_step_time "Database check" $(( SECONDS - start ))
        return 0
    fi

    # 1. Module versions (exit 0 = up to date, 2 = upgrade required)
    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "setup:db:status / app:config:status"
    else
        local db_output db_status=0
        db_output="$(magento_cli setup:db:status 2>&1)" || db_status=$?
        [[ -n "$LOG_FILE" ]] && printf '%s\n' "$db_output" >> "$LOG_FILE"
        case "$db_status" in
            0) ui_ok "setup:db:status: module versions up to date" ;;
            2) DB_UPGRADE_NEEDED=true; DB_UPGRADE_REASON="setup:db:status reports pending changes"
               ui_info "setup:db:status: upgrade required" ;;
            *) printf '%s\n' "$db_output" | tail -5 >&2
               die "setup:db:status failed (exit $db_status) - cannot determine database state" ;;
        esac

        local cfg_output cfg_status=0
        cfg_output="$(magento_cli app:config:status 2>&1)" || cfg_status=$?
        [[ -n "$LOG_FILE" ]] && printf '%s\n' "$cfg_output" >> "$LOG_FILE"
        case "$cfg_status" in
            0) ui_ok "app:config:status: configuration up to date" ;;
            2) CONFIG_IMPORT_NEEDED=true; ui_info "app:config:status: import required" ;;
            *) printf '%s\n' "$cfg_output" | tail -5 >&2
               die "app:config:status failed (exit $cfg_status) - cannot determine config state" ;;
        esac
    fi

    # 2. Fingerprint of schema / patch related files
    local stored=""
    DB_FINGERPRINT="$(compute_db_fingerprint)"
    [[ -f "$DEPLOY_STATE_DIR/db-fingerprint" ]] && stored="$(head -1 "$DEPLOY_STATE_DIR/db-fingerprint")"
    if [[ -z "$stored" ]]; then
        if [[ "$DB_UPGRADE_NEEDED" != "true" ]]; then
            DB_UPGRADE_NEEDED=true
            DB_UPGRADE_REASON="no database fingerprint baseline yet (first run)"
        fi
        ui_info "Database fingerprint: no baseline yet - setup:upgrade will run once to establish it"
    elif [[ "$stored" != "$DB_FINGERPRINT" ]]; then
        if [[ "$DB_UPGRADE_NEEDED" != "true" ]]; then
            DB_UPGRADE_NEEDED=true
            DB_UPGRADE_REASON="db_schema.xml / module.xml / Setup files changed"
        fi
        ui_info "Database fingerprint changed (db_schema.xml, module.xml or Setup/ files)"
    else
        ui_ok "Database fingerprint unchanged (no new schema or patches)"
    fi

    # 3. Policy
    case "$DB_UPGRADE" in
        always)
            DB_UPGRADE_NEEDED=true
            DB_UPGRADE_REASON="DB_UPGRADE=always"
            ;;
        never)
            if [[ "$DB_UPGRADE_NEEDED" == "true" ]]; then
                ui_warn "DB_UPGRADE=never: skipping setup:upgrade although $DB_UPGRADE_REASON"
            fi
            DB_UPGRADE_NEEDED=false
            ;;
    esac

    if [[ "$DB_UPGRADE_NEEDED" == "true" ]]; then
        ui_note "setup:upgrade WILL run in the release phase ($DB_UPGRADE_REASON)"
        if [[ "$CONFIG_IMPORT_NEEDED" == "true" ]]; then
            ui_note "pending config import is covered by setup:upgrade"
        fi
    else
        ui_note "setup:upgrade skipped - no database changes"
        # Config import is safe on a live site; running it before the build
        # lets static-content:deploy see new store views / themes
        if [[ "$CONFIG_IMPORT_NEEDED" == "true" ]]; then
            if ! run_cmd --show-output --label "app:config:import" -- magento_cli app:config:import --no-interaction; then
                die "Config import failed"
            fi
        fi
    fi

    record_step_time "Database check" $(( SECONDS - start ))
}

# ───────────────────────────────────────────────────────────────────
# Production mode (env.php only, no compilation - the build does that)
# ───────────────────────────────────────────────────────────────────
ensure_production_mode() {
    local current_mode
    current_mode="$(get_current_mode)"
    if [[ "$current_mode" == "production" ]]; then
        ui_ok "Application mode: production"
        return 0
    fi
    if ! run_cmd --label "deploy:mode:set production --skip-compilation (was: ${current_mode:-unknown})" -- \
        magento_cli deploy:mode:set production --skip-compilation; then
        die "Failed to set production mode"
    fi
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Build (site live)
# The code tree is cloned into BUILD_ROOT (hardlinks on Linux, APFS
# clones on macOS, plain copy as fallback) and bin/magento of the clone
# compiles into the clone's generated/ and pub/static/. Nothing in the
# clone writes into app/, lib/ or vendor/, so sharing inodes is safe.
# ───────────────────────────────────────────────────────────────────
CLONE_MODE=""

# Clone a directory or file: $1 = source, $2 = destination (must not exist)
clone_path() {
    local src="$1" dst="$2"
    if [[ -z "$CLONE_MODE" ]]; then
        if cp -al "$src" "$dst" 2>/dev/null; then
            CLONE_MODE="hardlink"; return 0
        fi
        rm -rf "$dst"
        if [[ "$PLATFORM" == "Darwin" ]] && cp -Rpc "$src" "$dst" 2>/dev/null; then
            CLONE_MODE="apfs-clone"; return 0
        fi
        rm -rf "$dst"
        CLONE_MODE="copy"
    fi
    case "$CLONE_MODE" in
        hardlink)   cp -al "$src" "$dst" ;;
        apfs-clone) cp -Rpc "$src" "$dst" ;;
        *)          cp -Rp "$src" "$dst" ;;
    esac
}

# Replace a cloned file with a private copy so writes cannot reach the
# live file through a shared inode
detach_file() {
    local rel="$1"
    [[ -f "$BUILD_ROOT/$rel" ]] || return 0
    local tmp="$BUILD_ROOT/$rel.detach.$$"
    cp -p "$BUILD_ROOT/$rel" "$tmp" && mv -f "$tmp" "$BUILD_ROOT/$rel"
}

# Same for a directory (composer rewrites vendor/composer/*.php in place)
detach_dir() {
    local rel="$1"
    [[ -d "$BUILD_ROOT/$rel" ]] || return 0
    local tmp="$BUILD_ROOT/$rel.detach.$$"
    cp -Rp "$BUILD_ROOT/$rel" "$tmp" && rm -rf "${BUILD_ROOT:?}/${rel:?}" && mv "$tmp" "$BUILD_ROOT/$rel"
}

create_build_clone() {
    CURRENT_STEP="Cloning code tree"
    local start=$SECONDS
    local entries=(app bin lib setup vendor composer.json composer.lock)
    local entry

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would clone ${entries[*]} into $(rel_path "$BUILD_ROOT")"
        return 0
    fi

    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT/pub/static" "$BUILD_ROOT/generated" "$BUILD_ROOT/var" \
        || die "Cannot create build directory $BUILD_ROOT"

    for entry in "${entries[@]}"; do
        [[ -e "$MAGENTO_DIR/$entry" ]] || continue
        clone_path "$MAGENTO_DIR/$entry" "$BUILD_ROOT/$entry" \
            || die "Failed to clone $entry into the build directory"
    done

    # Files Magento may rewrite in place must not share inodes with live
    detach_file app/etc/env.php
    detach_file app/etc/config.php

    # Static content deployment only reads media; share it instead of copying
    if [[ -d "$MAGENTO_DIR/pub/media" ]]; then
        ln -s "$MAGENTO_DIR/pub/media" "$BUILD_ROOT/pub/media"
    fi

    # Keeping the current generated code: static deploy must see it
    if [[ "$SKIP_DI_COMPILE" == "true" && "$SKIP_STATIC" != "true" ]]; then
        for entry in generated/code generated/metadata; do
            [[ -d "$MAGENTO_DIR/$entry" ]] || continue
            clone_path "$MAGENTO_DIR/$entry" "$BUILD_ROOT/$entry" \
                || die "Failed to clone $entry into the build directory"
        done
    fi

    [[ -f "$BUILD_ROOT/bin/magento" ]] || die "Build clone is incomplete: bin/magento missing"
    chmod +x "$BUILD_ROOT/bin/magento" 2>/dev/null || true

    ui_ok "Cloned code tree into $(rel_path "$BUILD_ROOT") ($CLONE_MODE)" "$(format_duration $(( SECONDS - start )))"
    record_step_time "Clone code tree" $(( SECONDS - start ))
}

di_compile() {
    if [[ "$SKIP_DI_COMPILE" == "true" ]]; then
        ui_skip "setup:di:compile" "(--skip-di-compile, current generated code is kept)"
        return 0
    fi
    local start=$SECONDS
    if ! run_cmd --retries 2 --label "setup:di:compile" -- magento_cli_in "$BUILD_ROOT" setup:di:compile; then
        die "DI compilation failed"
    fi
    if [[ "$DRY_RUN" != "true" ]] && [[ ! -d "$BUILD_ROOT/generated/code" || ! -d "$BUILD_ROOT/generated/metadata" ]]; then
        die "setup:di:compile finished but generated/code or generated/metadata is missing in the build"
    fi
    record_step_time "DI compilation" $(( SECONDS - start ))
}

# Optimized classmap built against the NEW generated code, inside the
# clone. vendor/composer and vendor/autoload.php are detached first so
# composer cannot write through shared inodes into the live tree, and
# are swapped into place together with generated/.
dump_autoload_in_build() {
    if [[ "$SKIP_DI_COMPILE" == "true" ]]; then
        ui_skip "composer dump-autoload --optimize" "(--skip-di-compile, current autoloader is kept)"
        return 0
    fi
    local start=$SECONDS
    if [[ "$DRY_RUN" != "true" ]]; then
        detach_dir vendor/composer
        detach_file vendor/autoload.php
        detach_file app/etc/NonComposerComponentRegistration.php
    fi
    # --apcu is harmless without the extension: the ClassLoader only uses
    # APCu when it is actually loaded at runtime. --no-plugins: plugin
    # side effects already happened during the live composer install.
    if ! run_cmd --label "composer dump-autoload --optimize --apcu (build)" -- \
        composer_cli dump-autoload --optimize --apcu --no-plugins --no-interaction --working-dir="$BUILD_ROOT"; then
        die "Composer dump-autoload failed"
    fi
    if [[ "$DRY_RUN" != "true" && ! -f "$BUILD_ROOT/vendor/composer/autoload_classmap.php" ]]; then
        die "composer dump-autoload finished but vendor/composer/autoload_classmap.php is missing in the build"
    fi
    record_step_time "Autoloader optimization" $(( SECONDS - start ))
}

# Worker executed by xargs: one setup:static-content:deploy per job
write_scd_worker() {
    local worker="$1"
    cat > "$worker" <<'WORKER'
#!/usr/bin/env bash
# Static content worker: argument is "area|theme|locale"
set -u
job="$1"
area="${job%%|*}"; rest="${job#*|}"
theme="${rest%%|*}"; locale="${rest#*|}"
log="$DEPLOY_JOB_LOG_DIR/${area}_${theme//\//_}_${locale}.log"

php_args=()
[[ -n "${DEPLOY_MEMORY_LIMIT:-}" ]] && php_args=(-d "memory_limit=$DEPLOY_MEMORY_LIMIT")

args=(setup:static-content:deploy "--area=$area" "--theme=$theme" --no-parent --force --max-execution-time=3600)
[[ "$area" == "adminhtml" ]] && args+=(--no-js-bundle)
# shellcheck disable=SC2206
args+=(${DEPLOY_SCD_EXTRA_ARGS:-} "$locale")

start=$(date +%s)
"$DEPLOY_PHP_BIN" ${php_args[@]+"${php_args[@]}"} "$DEPLOY_BUILD_ROOT/bin/magento" "${args[@]}" > "$log" 2>&1
rc=$?
secs=$(( $(date +%s) - start ))

if (( rc == 0 )); then
    echo "OK|$area|$theme|$locale|$secs" >> "$DEPLOY_PROGRESS_FILE"
    [[ "${DEPLOY_ANNOUNCE:-false}" == "true" ]] && echo "  + $area $theme $locale (${secs}s)"
    exit 0
fi

echo "FAIL|$area|$theme|$locale|$secs|$rc" >> "$DEPLOY_PROGRESS_FILE"
{
    echo "  x $area $theme $locale FAILED (exit $rc after ${secs}s) - last 15 lines:"
    tail -n 15 "$log" | sed 's/^/    | /'
} >&2
exit 1
WORKER
    chmod +x "$worker"
}

SCD_PROGRESS_FILE=""
_scd_progress() {
    local n=""
    [[ -f "$SCD_PROGRESS_FILE" ]] && n="$(grep -c . "$SCD_PROGRESS_FILE" 2>/dev/null)"
    printf '%s/%s jobs' "${n:-0}" "$SCD_JOB_COUNT"
}

deploy_static_content() {
    if [[ "$SKIP_STATIC" == "true" ]]; then
        ui_skip "setup:static-content:deploy" "(--skip-static, current static content is kept)"
        return 0
    fi
    CURRENT_STEP="Static content deployment"
    local start=$SECONDS

    local fe_langs=() be_langs=() jobs=() theme lang
    split_list fe_langs "$FRONTEND_LANGUAGES"
    split_list be_langs "$BACKEND_LANGUAGES"

    if (( ${#FRONTEND_THEMES[@]} > 0 )); then
        (( ${#fe_langs[@]} > 0 )) || die "FRONTEND_LANGUAGES is empty"
        for theme in "${FRONTEND_THEMES[@]}"; do
            for lang in "${fe_langs[@]}"; do jobs+=("frontend|$theme|$lang"); done
        done
    else
        ui_warn "No frontend themes configured - skipping frontend static content"
    fi
    (( ${#be_langs[@]} > 0 )) || die "BACKEND_LANGUAGES is empty"
    for lang in "${be_langs[@]}"; do jobs+=("adminhtml|$BACKEND_THEME|$lang"); done

    SCD_JOB_COUNT=${#jobs[@]}
    local workers=$PARALLEL_JOBS
    (( workers > SCD_JOB_COUNT )) && workers=$SCD_JOB_COUNT

    ui_note "frontend: ${FRONTEND_THEMES[*]-none} $SYM_TIMES ${fe_langs[*]-}"
    ui_note "backend:  $BACKEND_THEME $SYM_TIMES ${be_langs[*]}"
    [[ -n "$SCD_EXTRA_ARGS" ]] && ui_note "extra args: $SCD_EXTRA_ARGS"

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would run $SCD_JOB_COUNT setup:static-content:deploy processes, $workers in parallel"
        return 0
    fi

    local job_log_dir="${LOG_FILE%.log}_scd"
    local worker="$BUILD_DIR/scd-worker.sh"
    local job_list="$BUILD_DIR/scd-jobs.txt"
    SCD_PROGRESS_FILE="$BUILD_DIR/scd-progress.txt"
    mkdir -p "$job_log_dir"
    : > "$SCD_PROGRESS_FILE"
    printf '%s\n' "${jobs[@]}" > "$job_list"
    write_scd_worker "$worker"

    local announce=false
    if [[ "$IS_TTY" != "true" || "$VERBOSE" == "true" ]]; then
        announce=true
        echo "  ${SYM_STEP} Deploying static content: $SCD_JOB_COUNT jobs, $workers in parallel..."
    fi

    env DEPLOY_PHP_BIN="$PHP_BIN" \
        DEPLOY_MEMORY_LIMIT="$PHP_MEMORY_LIMIT" \
        DEPLOY_BUILD_ROOT="$BUILD_ROOT" \
        DEPLOY_JOB_LOG_DIR="$job_log_dir" \
        DEPLOY_PROGRESS_FILE="$SCD_PROGRESS_FILE" \
        DEPLOY_SCD_EXTRA_ARGS="$SCD_EXTRA_ARGS" \
        DEPLOY_ANNOUNCE="$announce" \
        xargs -P "$workers" -n 1 bash "$worker" < "$job_list" &
    CHILD_PID=$!
    _wait_with_spinner "$CHILD_PID" "Deploying static content ($workers parallel)" _scd_progress
    wait "$CHILD_PID"
    local rc=$?
    CHILD_PID=""

    # Merge the per-job logs into the main log, in job order
    if [[ -n "$LOG_FILE" ]]; then
        local job f
        for job in "${jobs[@]}"; do
            f="$job_log_dir/${job%%|*}_$(echo "${job#*|}" | sed 's#|#_#; s#/#_#g').log"
            [[ -f "$f" ]] || continue
            {
                echo "----- static content: $job -----"
                cat "$f"
                echo "----- end -----"
            } >> "$LOG_FILE"
        done
    fi

    local ok_count fail_count slowest
    ok_count="$(grep -c '^OK|' "$SCD_PROGRESS_FILE" 2>/dev/null)"; ok_count="${ok_count:-0}"
    fail_count="$(grep -c '^FAIL|' "$SCD_PROGRESS_FILE" 2>/dev/null)"; fail_count="${fail_count:-0}"
    slowest="$(grep '^OK|' "$SCD_PROGRESS_FILE" 2>/dev/null | sort -t'|' -k5 -n -r | head -1)"

    if (( rc != 0 || fail_count > 0 || ok_count != SCD_JOB_COUNT )); then
        ui_fail "Static content: $ok_count/$SCD_JOB_COUNT jobs succeeded, $fail_count failed (xargs exit $rc)"
        grep '^FAIL|' "$SCD_PROGRESS_FILE" 2>/dev/null | while IFS='|' read -r _ area theme locale secs code; do
            ui_fail "  $area $theme $locale (exit $code) $SYM_ARROW $(rel_path "$job_log_dir")/${area}_${theme//\//_}_${locale}.log"
        done
        die "Static content deployment failed - live site untouched"
    fi

    [[ ! -f "$BUILD_ROOT/pub/static/deployed_version.txt" ]] \
        && ui_warn "pub/static/deployed_version.txt missing after static deploy"

    rm -rf "$job_log_dir"
    local slow_note=""
    if [[ -n "$slowest" ]]; then
        IFS='|' read -r _ area theme locale secs <<< "$slowest"
        slow_note="slowest: $area $theme $locale $(format_duration "$secs")"
    fi
    ui_ok "Static content: $SCD_JOB_COUNT jobs on $workers cores" "$(format_duration $(( SECONDS - start )))${slow_note:+ $SYM_DOT $slow_note}"
    record_step_time "Static content ($SCD_JOB_COUNT jobs)" $(( SECONDS - start ))
}

# Pre-built artifacts (--artifacts): stage them in BUILD_ROOT so the
# release phase can rename them into place
import_artifacts() {
    ui_phase "Build" "using pre-built artifacts from $ARTIFACTS_DIR"
    CURRENT_STEP="Importing artifacts"
    local start=$SECONDS

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would stage generated/ and pub/static/ from $ARTIFACTS_DIR"
        return 0
    fi

    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT/pub" "$BUILD_ROOT/generated"
    local entry
    if [[ "$SKIP_DI_COMPILE" != "true" ]]; then
        for entry in generated/code generated/metadata vendor/composer vendor/autoload.php; do
            [[ -e "$ARTIFACTS_DIR/$entry" ]] || continue
            mkdir -p "$BUILD_ROOT/$(dirname "$entry")"
            clone_path "$ARTIFACTS_DIR/$entry" "$BUILD_ROOT/$entry" || die "Failed to stage $entry"
        done
        [[ -f "$BUILD_ROOT/vendor/composer/autoload_classmap.php" ]] \
            || ui_warn "Artifacts contain no vendor/composer: the live autoloader is kept (it must not be an optimized classmap)"
    fi
    if [[ "$SKIP_STATIC" != "true" ]]; then
        clone_path "$ARTIFACTS_DIR/pub/static" "$BUILD_ROOT/pub/static" || die "Failed to stage pub/static"
        if [[ -d "$ARTIFACTS_DIR/var/view_preprocessed" ]]; then
            mkdir -p "$BUILD_ROOT/var"
            clone_path "$ARTIFACTS_DIR/var/view_preprocessed" "$BUILD_ROOT/var/view_preprocessed" \
                || die "Failed to stage var/view_preprocessed"
        fi
    fi
    ui_ok "Staged artifacts from $ARTIFACTS_DIR ($CLONE_MODE)" "$(format_duration $(( SECONDS - start )))"
    record_step_time "Import artifacts" $(( SECONDS - start ))
}

build_phase() {
    if [[ -n "$ARTIFACTS_DIR" ]]; then
        import_artifacts
        return 0
    fi
    if [[ "$SKIP_DI_COMPILE" == "true" && "$SKIP_STATIC" == "true" ]]; then
        ui_phase "Build" "skipped: generated code and static content are kept"
        return 0
    fi
    ui_phase "Build" "site live, building in $(rel_path "$BUILD_ROOT")"
    create_build_clone
    di_compile
    dump_autoload_in_build
    deploy_static_content
}

# ───────────────────────────────────────────────────────────────────
# Maintenance mode
# ───────────────────────────────────────────────────────────────────
maintenance_window_required() {
    case "$MAINTENANCE" in
        always) return 0 ;;
        never)  return 1 ;;
        *)      [[ "$DB_UPGRADE_NEEDED" == "true" ]] ;;
    esac
}

enable_maintenance() {
    local args=(maintenance:enable) ip
    if [[ -n "$MAINTENANCE_ALLOWED_IPS" ]]; then
        # shellcheck disable=SC2086
        for ip in ${MAINTENANCE_ALLOWED_IPS//,/ }; do args+=("--ip=$ip"); done
    fi
    if ! run_cmd --label "maintenance:enable${MAINTENANCE_ALLOWED_IPS:+ (allowed: ${MAINTENANCE_ALLOWED_IPS//,/ })}" -- magento_cli "${args[@]}"; then
        die "Failed to enable maintenance mode"
    fi
    MAINTENANCE_REQUESTED=true
    MAINTENANCE_WINDOW_USED=true
    MAINTENANCE_START=$SECONDS
    [[ "$DRY_RUN" != "true" ]] && MAINTENANCE_ENABLED=true
    return 0
}

disable_maintenance() {
    [[ "$MAINTENANCE_REQUESTED" != "true" ]] && return 0
    if ! run_cmd --label "maintenance:disable" -- magento_cli maintenance:disable; then
        die "Failed to disable maintenance mode"
    fi
    DOWNTIME_SECONDS=$(( DOWNTIME_SECONDS + SECONDS - MAINTENANCE_START ))
    MAINTENANCE_ENABLED=false
    MAINTENANCE_REQUESTED=false
    return 0
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Release
# ───────────────────────────────────────────────────────────────────

# Move one artifact from the build into place, keeping the live one in
# PREVIOUS_DIR. Two renames: the gap is microseconds.
swap_item() {
    local rel="$1"
    local live="$MAGENTO_DIR/$rel" new="$BUILD_ROOT/$rel" prev="$PREVIOUS_DIR/$rel"
    [[ -e "$new" ]] || return 0
    mkdir -p "$(dirname "$prev")"
    if [[ -e "$live" ]]; then
        mv "$live" "$prev" || die "Could not move $rel aside (live site unchanged)"
    fi
    if ! mv "$new" "$live"; then
        [[ -e "$prev" ]] && mv "$prev" "$live"
        die "Could not move new $rel into place (previous version restored)"
    fi
    SWAPPED_ITEMS+=("$rel")
}

# Move a live-only path into PREVIOUS_DIR (runtime caches that must not
# survive a static content deployment)
retire_item() {
    local rel="$1"
    local live="$MAGENTO_DIR/$rel" prev="$PREVIOUS_DIR/$rel"
    [[ -e "$live" ]] || return 0
    mkdir -p "$(dirname "$prev")"
    mv "$live" "$prev" 2>/dev/null || rm -rf "$live"
}

swap_artifacts() {
    CURRENT_STEP="Swapping artifacts"
    local start=$SECONDS
    local items=() entry name

    if [[ "$SKIP_DI_COMPILE" != "true" ]]; then
        # classmap and generated code must switch together
        items+=(generated/code generated/metadata vendor/composer vendor/autoload.php)
    fi
    if [[ "$SKIP_STATIC" != "true" ]]; then
        items+=(var/view_preprocessed)
        if [[ "$DRY_RUN" == "true" ]]; then
            items+=("pub/static/frontend" "pub/static/adminhtml" "pub/static/deployed_version.txt")
        else
            for entry in "$BUILD_ROOT"/pub/static/* "$BUILD_ROOT"/pub/static/.[!.]*; do
                [[ -e "$entry" ]] || continue
                name="$(basename "$entry")"
                [[ "$name" == ".htaccess" ]] && continue
                items+=("pub/static/$name")
            done
        fi
    fi

    if (( ${#items[@]} == 0 )); then
        ui_skip "Artifact swap" "(nothing was built)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would swap into place: ${items[*]}"
        return 0
    fi

    rm -rf "$PREVIOUS_DIR"
    mkdir -p "$PREVIOUS_DIR"
    for entry in "${items[@]}"; do
        swap_item "$entry"
    done
    # Merged/minified bundles are built from the old sources
    if [[ "$SKIP_STATIC" != "true" ]]; then
        retire_item "pub/static/_cache"
    fi
    ARTIFACTS_SWAPPED=true

    ui_ok "Swapped ${#SWAPPED_ITEMS[@]} artifacts into place: ${SWAPPED_ITEMS[*]}" "$(format_duration $(( SECONDS - start )))"
    ui_note "previous versions kept in $(rel_path "$PREVIOUS_DIR") until the deployment is verified"
    record_step_time "Artifact swap" $(( SECONDS - start ))
}

run_setup_upgrade() {
    [[ "$DB_UPGRADE_NEEDED" == "true" ]] || return 0
    local start=$SECONDS
    if [[ "$MAINTENANCE_REQUESTED" != "true" ]]; then
        ui_warn "Running setup:upgrade on a LIVE site (MAINTENANCE=$MAINTENANCE)"
    fi
    # Generated code was compiled from this exact code in the build phase
    if ! run_cmd --show-output --label "setup:upgrade --keep-generated" -- \
        magento_cli setup:upgrade --keep-generated --no-interaction; then
        die "setup:upgrade failed"
    fi
    save_db_fingerprint
    record_step_time "Database upgrade" $(( SECONDS - start ))
}

flush_caches() {
    local start=$SECONDS
    if ! run_cmd --label "cache:flush" -- magento_cli cache:flush; then
        ui_warn "cache:flush returned non-zero (continuing - flush manually if needed)"
    fi
    record_step_time "Cache flush" $(( SECONDS - start ))
}

release_phase() {
    local window=false
    maintenance_window_required && window=true

    if [[ "$window" == "true" ]]; then
        local why="MAINTENANCE=$MAINTENANCE"
        [[ "$DB_UPGRADE_NEEDED" == "true" ]] && why="setup:upgrade ($DB_UPGRADE_REASON)"
        ui_phase "Release" "maintenance window: $why"
    else
        ui_phase "Release" "zero downtime: no maintenance window needed"
    fi
    local start=$SECONDS

    # Backup runs before the window so it does not add downtime
    [[ "$DB_UPGRADE_NEEDED" == "true" ]] && backup_database

    [[ "$window" == "true" ]] && enable_maintenance
    swap_artifacts
    run_setup_upgrade
    flush_caches
    opcache_reset
    [[ "$window" == "true" ]] && disable_maintenance

    record_step_time "Release" $(( SECONDS - start ))
    return 0
}

# ───────────────────────────────────────────────────────────────────
# PHASE: Verify
# ───────────────────────────────────────────────────────────────────
post_deployment_checks() {
    CURRENT_STEP="Post-deployment checks"
    local start=$SECONDS warnings=0 dir count

    for dir in generated/code generated/metadata pub/static; do
        if [[ -d "$MAGENTO_DIR/$dir" ]]; then
            count="$(find "$MAGENTO_DIR/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
            ui_note "$dir: $count files"
        else
            ui_warn "$dir: directory not found"
            (( warnings++ ))
        fi
    done

    if [[ "$SKIP_STATIC" != "true" && "$DRY_RUN" != "true" && ! -f "$MAGENTO_DIR/pub/static/deployed_version.txt" ]]; then
        ui_warn "pub/static/deployed_version.txt missing after static deploy"
        (( warnings++ ))
    fi

    local current_mode
    current_mode="$(get_current_mode)"
    if [[ "$current_mode" == "production" ]]; then
        ui_ok "Application mode: production"
    else
        ui_warn "Application mode: ${current_mode:-unknown} (expected: production)"
        (( warnings++ ))
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        local maint_status
        maint_status="$(magento_cli maintenance:status 2>/dev/null || true)"
        if [[ "$maint_status" == *"is active"* && "$maint_status" != *"not active"* ]]; then
            ui_warn "Maintenance mode is still ACTIVE - the site is offline!"
            (( warnings++ ))
        else
            ui_ok "Maintenance mode: off"
        fi
    fi

    if (( warnings > 0 )); then
        ui_warn "Post-deployment checks completed with $warnings warning(s)"
    else
        ui_ok "Post-deployment checks passed"
    fi
    record_step_time "Post-deployment checks" $(( SECONDS - start ))
}

# Remove the replaced artifacts once the new release is verified
cleanup_previous_artifacts() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ -d "$PREVIOUS_DIR" ]] || return 0
    if [[ "$KEEP_PREVIOUS" == "true" ]]; then
        ui_note "previous artifacts kept in $(rel_path "$PREVIOUS_DIR") (--keep-previous)"
        return 0
    fi
    local start=$SECONDS
    rm -rf "$PREVIOUS_DIR" &
    CHILD_PID=$!
    _wait_with_spinner "$CHILD_PID" "Removing previous artifacts"
    wait "$CHILD_PID" || true
    CHILD_PID=""
    ui_ok "Removed previous artifacts" "$(format_duration $(( SECONDS - start )))"
}

verify_phase() {
    ui_phase "Verify"
    health_check
    post_deployment_checks
    cleanup_previous_artifacts
    [[ "$BUILD_ONLY" != "true" && "$DRY_RUN" != "true" ]] && rm -rf "$BUILD_ROOT"
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Pipeline helpers: --build-only / --push
# ───────────────────────────────────────────────────────────────────
push_artifacts() {
    [[ -n "$PUSH_TARGET" ]] || return 0
    ui_phase "Push artifacts" "$PUSH_TARGET"
    local start=$SECONDS
    local host="${PUSH_TARGET%%:*}" remote_dir="${PUSH_TARGET#*:}"
    [[ "$PUSH_TARGET" == *:* && -n "$host" && -n "$remote_dir" ]] \
        || die "--push expects user@host:/path/to/magento"
    command -v rsync >/dev/null 2>&1 || die "rsync is required for --push"

    local incoming="$remote_dir/var/deploy/incoming"
    local paths=() rel
    for rel in generated/code generated/metadata vendor/composer pub/static var/view_preprocessed; do
        [[ -e "$BUILD_ROOT/$rel" ]] && paths+=("$rel")
    done
    if [[ -f "$BUILD_ROOT/vendor/autoload.php" ]]; then
        if ! run_cmd --label "ssh $host mkdir -p $incoming/vendor" -- ssh "$host" "mkdir -p '$incoming/vendor'"; then
            die "Cannot create $incoming/vendor on $host"
        fi
        if ! run_cmd --label "rsync vendor/autoload.php $SYM_ARROW $host" -- \
            rsync -az -e ssh "$BUILD_ROOT/vendor/autoload.php" "$host:$incoming/vendor/autoload.php"; then
            die "rsync of vendor/autoload.php failed"
        fi
    fi
    (( ${#paths[@]} > 0 )) || die "Nothing to push: $BUILD_ROOT has no artifacts"

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_dry "Would rsync ${paths[*]} to $host:$incoming"
        return 0
    fi

    if ! run_cmd --label "ssh $host mkdir -p $incoming" -- ssh "$host" "mkdir -p '$incoming'"; then
        die "Cannot create $incoming on $host"
    fi
    for rel in "${paths[@]}"; do
        if ! run_cmd --label "rsync $rel $SYM_ARROW $host" -- \
            rsync -az --delete -e ssh "$BUILD_ROOT/$rel/" "$host:$incoming/$rel/"; then
            die "rsync of $rel failed"
        fi
    done
    ui_ok "Artifacts uploaded to $host:$incoming" "$(format_duration $(( SECONDS - start )))"
    record_step_time "Push artifacts" $(( SECONDS - start ))

    if [[ "$PUSH_RUN" == "true" ]]; then
        local remote_cmd="cd '$remote_dir' && ./deploy.sh --artifacts '$incoming' --no-interaction"
        ui_note "running on $host: $remote_cmd"
        if ! ssh -t "$host" "$remote_cmd" 2>&1 | sed 's/^/    /'; then
            die "Remote deployment on $host failed"
        fi
    else
        ui_note "release on the server with: cd $remote_dir && ./deploy.sh --artifacts $incoming"
    fi
}

# ───────────────────────────────────────────────────────────────────
# Log retention (LOG_RETENTION_DAYS=0 disables)
# ───────────────────────────────────────────────────────────────────
clean_old_logs() {
    if ! [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( LOG_RETENTION_DAYS == 0 )); then
        return 0
    fi
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    [[ -d "$log_dir" ]] || return 0
    [[ "$DRY_RUN" == "true" ]] && return 0

    local count=0 old_file
    while IFS= read -r -d '' old_file; do
        rm -rf "$old_file"; (( count++ ))
    done < <(find "$log_dir" -maxdepth 1 \( -name 'deploy_*.log' -o -name 'deploy_report_*.txt' -o -name 'deploy_*_scd' \) -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)

    # Legacy logs/reports from the old script in the project root
    while IFS= read -r -d '' old_file; do
        rm -f "$old_file"; (( count++ ))
    done < <(find "$MAGENTO_DIR" -maxdepth 1 \( -name 'deployment_*.log' -o -name 'deployment_report_*.txt' \) -type f -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)

    if [[ -d "$MAGENTO_DIR/var/backups" ]]; then
        while IFS= read -r -d '' old_file; do
            rm -f "$old_file"; (( count++ ))
        done < <(find "$MAGENTO_DIR/var/backups" -maxdepth 1 -name 'deploy_db_*.sql.gz' -type f -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)
    fi

    (( count > 0 )) && _file_log INFO "Cleaned $count old log/report/backup file(s) older than ${LOG_RETENTION_DAYS} days"
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Report and summary
# ───────────────────────────────────────────────────────────────────
generate_report() {
    local status="$1" total_seconds="$2"
    local report_file
    report_file="$MAGENTO_DIR/var/log/deploy_report_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$(dirname "$report_file")" 2>/dev/null || report_file="${LOG_FILE%.log}_report.txt"

    local git_info="N/A"
    if command -v git >/dev/null 2>&1 && [[ -d "$MAGENTO_DIR/.git" ]]; then
        git_info="$(cd "$MAGENTO_DIR" && git log --oneline -1 2>/dev/null || echo "N/A")"
    fi
    local php_info composer_info
    php_info="$("$PHP_BIN" -v 2>/dev/null | head -1)"
    composer_info="$(composer_cli --version 2>/dev/null | head -1)"

    cat > "$report_file" << REPORT
================================================================================
                       MAGENTO 2 DEPLOYMENT REPORT
================================================================================
Date:           $(date)
Status:         $status$([[ "$status" != "SUCCESS" && -n "$CURRENT_STEP" ]] && printf '\nFailed during:  %s (%s)' "$CURRENT_STEP" "$CURRENT_PHASE")
Duration:       $(format_duration "$total_seconds")
Downtime:       $(format_duration "$DOWNTIME_SECONDS") (maintenance window used: $MAINTENANCE_WINDOW_USED)
Platform:       $PLATFORM
Git revision:   $git_info
Script version: $DEPLOY_VERSION

CONFIGURATION:
  Magento dir:       $MAGENTO_DIR
  PHP:               ${php_info:-N/A}
  Composer:          ${composer_info:-N/A}
  Frontend themes:   ${FRONTEND_THEMES[*]-none}
  Backend theme:     $BACKEND_THEME
  Frontend langs:    $FRONTEND_LANGUAGES
  Backend langs:     $BACKEND_LANGUAGES
  Parallel jobs:     $PARALLEL_JOBS
  Memory limit:      ${PHP_MEMORY_LIMIT:-php.ini default}
  Maintenance:       $MAINTENANCE
  DB upgrade:        $DB_UPGRADE (ran: $DB_UPGRADE_NEEDED${DB_UPGRADE_REASON:+, reason: $DB_UPGRADE_REASON})
  Config import:     $CONFIG_IMPORT_NEEDED
  Artifacts swapped: $ARTIFACTS_SWAPPED (${SWAPPED_ITEMS[*]-none})
  DB backup:         ${LAST_BACKUP_FILE:-none}
  Health check:      ${HEALTHCHECK_URL:-none}

STEP TIMINGS:
$(format_step_timings)

ERRORS AND WARNINGS:
$(grep -E '\] (ERROR|WARN): ' "$LOG_FILE" 2>/dev/null | head -50 || echo "  None")

DISK USAGE: $(get_disk_usage_percent "$MAGENTO_DIR")
Full log:   $LOG_FILE
================================================================================
REPORT
    _file_log INFO "Report saved: $report_file"
    LAST_REPORT_FILE="$report_file"
}
LAST_REPORT_FILE=""

display_summary() {
    local status="$1" total_seconds="$2" exit_code="${3:-0}"
    local error_count warning_count
    error_count="$(count_log_lines '\] ERROR: ')"
    warning_count="$(count_log_lines '\] WARN: ')"

    echo
    if [[ "$status" == "SUCCESS" ]]; then
        if [[ "$BUILD_ONLY" == "true" ]]; then
            echo " ${BG_GREEN}${BOLD}  BUILD COMPLETE  ${RESET}  ${DIM}in $(format_duration "$total_seconds")${RESET}"
        else
            echo " ${BG_GREEN}${BOLD}  DEPLOYMENT COMPLETE  ${RESET}  ${DIM}in $(format_duration "$total_seconds") $SYM_DOT downtime $(format_duration "$DOWNTIME_SECONDS")${RESET}"
        fi
    else
        case "$exit_code" in
            129|130|143) echo " ${BG_YELLOW}${BOLD}  DEPLOYMENT INTERRUPTED  ${RESET}  ${DIM}after $(format_duration "$total_seconds")${RESET}" ;;
            *)           echo " ${BG_RED}${BOLD}  DEPLOYMENT FAILED  ${RESET}  ${DIM}after $(format_duration "$total_seconds")${RESET}" ;;
        esac
        echo
        [[ -n "$CURRENT_STEP" ]] && ui_kv "Failed step" "$CURRENT_STEP${CURRENT_PHASE:+ ($CURRENT_PHASE)}"

        # Recovery guidance: what state is the live site in?
        if [[ "$MAINTENANCE_ENABLED" == "true" ]]; then
            echo "  ${YELLOW}${SYM_WARN} Maintenance mode is still ENABLED - the site is offline.${RESET}"
            echo "    Fix the problem, then reopen with:"
            echo "      $PHP_BIN $MAGENTO_DIR/bin/magento maintenance:disable"
        fi
        if [[ "$ARTIFACTS_SWAPPED" == "true" ]]; then
            echo "  ${YELLOW}${SYM_WARN} New artifacts are already in place; the previous ones are in:${RESET}"
            echo "      $PREVIOUS_DIR"
            echo "    To restore them move each entry back (e.g. generated/code, pub/static/frontend)."
        elif [[ "$DEPLOYMENT_STARTED" == "true" && "$DRY_RUN" != "true" ]]; then
            if [[ "$COMPOSER_RAN" == "true" ]]; then
                echo "  ${GREEN}${SYM_OK} Generated code and static content were not touched (composer install already ran in place).${RESET}"
            else
                echo "  ${GREEN}${SYM_OK} The live site was not touched: previous generated code and static content are still in place.${RESET}"
            fi
        fi
    fi

    echo
    ui_kv "Log" "$LOG_FILE"
    [[ -n "$LAST_REPORT_FILE" ]] && ui_kv "Report" "$LAST_REPORT_FILE"
    [[ -n "$LAST_BACKUP_FILE" ]] && ui_kv "DB backup" "$LAST_BACKUP_FILE"
    if [[ "$DRY_RUN" == "true" ]]; then
        ui_kv "" "${YELLOW}(dry run - no changes were made)${RESET}"
    fi

    if (( ${#STEP_TIMINGS[@]} > 0 )); then
        echo
        echo "  ${BOLD}Step timings${RESET}"
        format_step_timings
    fi
    if (( error_count > 0 || warning_count > 0 )); then
        echo
        (( error_count > 0 ))   && echo "  ${RED}${SYM_FAIL} $error_count error(s)${RESET}"
        (( warning_count > 0 )) && echo "  ${YELLOW}${SYM_WARN} $warning_count warning(s)${RESET} ${DIM}(see log)${RESET}"
    fi
    echo
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Configuration overview (start of a run)
# ───────────────────────────────────────────────────────────────────
display_config() {
    local git_info=""
    if command -v git >/dev/null 2>&1 && [[ -d "$MAGENTO_DIR/.git" ]]; then
        git_info="$(cd "$MAGENTO_DIR" && git log -1 --format='%h %s' 2>/dev/null | cut -c1-60)"
    fi
    local width=66
    local bar
    bar="$(printf '%*s' "$width" '' | tr ' ' "$SYM_BAR")"
    echo
    echo "${MAGENTA}${bar}${RESET}"
    printf '%s  Magento 2 zero-downtime deploy%s%*s%sv%s%s\n' "$BOLD" "$RESET" $(( width - 32 - ${#DEPLOY_VERSION} - 3 )) '' "$DIM" "$DEPLOY_VERSION" "$RESET"
    echo "${MAGENTA}${bar}${RESET}"
    [[ -n "$DEPLOY_CONFIG" && -f "$DEPLOY_CONFIG" ]] && ui_kv "Config file" "$DEPLOY_CONFIG"
    ui_kv "Magento dir" "$MAGENTO_DIR${git_info:+  ${DIM}($git_info)${RESET}}"
    ui_kv "PHP" "$PHP_BIN  ${DIM}memory_limit ${PHP_MEMORY_LIMIT:-php.ini default}${RESET}"
    ui_kv "Composer" "$COMPOSER_BIN"
    ui_kv "Frontend" "${FRONTEND_THEMES[*]-none}  ${DIM}${SYM_TIMES}${RESET}  ${FRONTEND_LANGUAGES//,/ }"
    ui_kv "Backend" "$BACKEND_THEME  ${DIM}${SYM_TIMES}${RESET}  ${BACKEND_LANGUAGES//,/ }"
    ui_kv "Parallel" "${PARALLEL_JOBS:-auto (CPU cores)} static-content processes"
    ui_kv "DB upgrade" "$DB_UPGRADE  ${DIM}(setup:upgrade only on database changes)${RESET}"
    ui_kv "Maintenance" "$MAINTENANCE  ${DIM}(auto = only while setup:upgrade runs)${RESET}"
    [[ -n "$ARTIFACTS_DIR" ]] && ui_kv "Artifacts" "$ARTIFACTS_DIR"
    [[ -n "$HEALTHCHECK_URL" ]] && ui_kv "Health check" "$HEALTHCHECK_URL"
    [[ "$DB_BACKUP" == "true" || -n "$DB_BACKUP_CMD" ]] && ui_kv "DB backup" "enabled"
    [[ -n "$OPCACHE_RESET_CMD" ]] && ui_kv "OPcache reset" "$OPCACHE_RESET_CMD"
    ui_kv "Log" "$LOG_FILE"

    local flags=()
    [[ "$SKIP_COMPOSER"   == "true" ]] && flags+=("skip-composer")
    [[ "$SKIP_DB_CHECK"   == "true" ]] && flags+=("skip-db-check")
    [[ "$SKIP_STATIC"     == "true" ]] && flags+=("skip-static")
    [[ "$SKIP_DI_COMPILE" == "true" ]] && flags+=("skip-di-compile")
    [[ "$BUILD_ONLY"      == "true" ]] && flags+=("build-only")
    [[ "$KEEP_PREVIOUS"   == "true" ]] && flags+=("keep-previous")
    [[ "$DRY_RUN"         == "true" ]] && flags+=("dry-run")
    [[ "$VERBOSE"         == "true" ]] && flags+=("verbose")
    (( ${#flags[@]} > 0 )) && ui_kv "Flags" "${YELLOW}${flags[*]}${RESET}"

    echo
    echo "  ${DIM}Pipeline: preflight $SYM_ARROW composer (live) $SYM_ARROW database check $SYM_ARROW build (live) $SYM_ARROW release $SYM_ARROW verify${RESET}"
    return 0
}

# ───────────────────────────────────────────────────────────────────
# Config wizard (--init): detect settings from the Magento DB/filesystem
# ───────────────────────────────────────────────────────────────────
generate_config_wizard() {
    echo "${BOLD}Magento 2 deployment - configuration wizard${RESET}"
    echo
    echo "Detects your Magento configuration and writes .deploy.env"
    echo

    local input="" candidate resolved

    local mage_dir="${MAGENTO_DIR:-.}"
    [[ -d "$mage_dir" ]] && mage_dir="$(cd "$mage_dir" && pwd)"
    printf '  Magento directory %s[%s]%s: ' "$CYAN" "$mage_dir" "$RESET"
    read -r input
    [[ -n "$input" ]] && mage_dir="$input"
    if [[ ! -f "$mage_dir/bin/magento" ]]; then
        echo "${RED}ERROR: bin/magento not found in $mage_dir${RESET}" >&2
        exit 1
    fi

    local php_bin="${PHP_BIN:-php}"
    for candidate in "$php_bin" php8.4 php8.3 php8.2 php8.1 php; do
        if command -v "$candidate" >/dev/null 2>&1; then php_bin="$candidate"; break; fi
    done
    local php_ver
    php_ver="$("$php_bin" -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")"
    printf '  PHP binary %s[%s (v%s)]%s: ' "$CYAN" "$php_bin" "$php_ver" "$RESET"
    read -r input
    [[ -n "$input" ]] && php_bin="$input"

    local comp_bin=""
    for candidate in "${COMPOSER_BIN:-composer}" composer composer.phar "$mage_dir/composer.phar"; do
        if resolved="$(command -v "$candidate" 2>/dev/null)"; then
            comp_bin="$resolved"; break
        elif [[ -f "$candidate" ]]; then
            comp_bin="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"; break
        fi
    done
    [[ -z "$comp_bin" ]] && comp_bin="composer"
    printf '  Composer binary %s[%s]%s: ' "$CYAN" "$comp_bin" "$RESET"
    read -r input
    [[ -n "$input" ]] && comp_bin="$input"

    echo
    echo "  ${YELLOW}Detecting themes and locales from the database...${RESET}"
    local detect_php
    read -r -d '' detect_php <<'PHPCODE' || true
$env = @include $argv[1] . '/app/etc/env.php';
if (!is_array($env)) { exit(1); }
$db = isset($env['db']['connection']['default']) ? $env['db']['connection']['default'] : array();
if (empty($db['host']) || empty($db['dbname'])) { exit(1); }
$dsn = 'mysql:host=' . $db['host'];
if (!empty($db['port'])) { $dsn .= ';port=' . $db['port']; }
$dsn .= ';dbname=' . $db['dbname'];
$prefix = isset($db['table_prefix']) ? $db['table_prefix'] : '';
try {
    $options = array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5);
    $pdo = new PDO($dsn, isset($db['username']) ? $db['username'] : '', isset($db['password']) ? $db['password'] : '', $options);
    $stmt = $pdo->query("SELECT DISTINCT t.area, t.theme_path
        FROM {$prefix}core_config_data c
        JOIN {$prefix}theme t ON c.value = t.theme_id
        WHERE c.path = 'design/theme/theme_id' AND c.value IS NOT NULL");
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        echo 'THEME:' . $row['area'] . ':' . $row['theme_path'] . PHP_EOL;
    }
    $stmt = $pdo->query("SELECT DISTINCT value FROM {$prefix}core_config_data
        WHERE path = 'general/locale/code' AND value IS NOT NULL");
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        echo 'LOCALE:' . $row['value'] . PHP_EOL;
    }
} catch (Exception $e) {
    exit(1);
}
PHPCODE

    local detect_output=""
    detect_output="$("$php_bin" -r "$detect_php" "$mage_dir" 2>/dev/null)" || true

    local frontend_themes=() locales=() backend_theme="Magento/backend" line
    if [[ -n "$detect_output" ]]; then
        while IFS= read -r line; do
            case "$line" in
                THEME:frontend:*)  frontend_themes+=("${line#THEME:frontend:}") ;;
                THEME:adminhtml:*) backend_theme="${line#THEME:adminhtml:}" ;;
                LOCALE:*)          locales+=("${line#LOCALE:}") ;;
            esac
        done <<< "$detect_output"
        echo "  ${GREEN}Detected themes and locales from the database${RESET}"
    fi

    if (( ${#frontend_themes[@]} == 0 )); then
        echo "  ${YELLOW}DB unavailable, scanning app/design/frontend/...${RESET}"
        local theme_reg theme_path
        while IFS= read -r theme_reg; do
            theme_path="$(dirname "$theme_reg")"
            theme_path="${theme_path#"$mage_dir/app/design/frontend/"}"
            if [[ "$theme_path" == */* ]] && [[ "$theme_path" != */*/* ]]; then
                frontend_themes+=("$theme_path")
            fi
        done < <(find "$mage_dir/app/design/frontend" -maxdepth 3 -name "registration.php" 2>/dev/null)
    fi
    (( ${#frontend_themes[@]} == 0 )) && frontend_themes=("Magento/luma")

    local themes_csv
    themes_csv="$(IFS=','; echo "${frontend_themes[*]}")"
    printf '  Frontend themes %s[%s]%s: ' "$CYAN" "$themes_csv" "$RESET"
    read -r input
    [[ -n "$input" ]] && themes_csv="$input"
    printf '  Backend theme %s[%s]%s: ' "$CYAN" "$backend_theme" "$RESET"
    read -r input
    [[ -n "$input" ]] && backend_theme="$input"

    local frontend_langs="" loc
    if (( ${#locales[@]} > 0 )); then
        for loc in "${locales[@]}"; do
            case " $frontend_langs " in
                *" $loc "*) ;;
                *) frontend_langs="${frontend_langs:+$frontend_langs }$loc" ;;
            esac
        done
        echo "  ${GREEN}Found locales: $frontend_langs${RESET}"
    else
        frontend_langs="en_GB"
        echo "  ${YELLOW}No locales detected, using default: en_GB${RESET}"
    fi
    local backend_langs="en_US"
    if [[ -n "$frontend_langs" && "$frontend_langs" != *en_US* ]]; then
        backend_langs="en_US $frontend_langs"
    fi
    printf '  Frontend languages %s[%s]%s: ' "$CYAN" "$frontend_langs" "$RESET"
    read -r input
    [[ -n "$input" ]] && frontend_langs="$input"
    printf '  Backend languages %s[%s]%s: ' "$CYAN" "$backend_langs" "$RESET"
    read -r input
    [[ -n "$input" ]] && backend_langs="$input"

    echo
    local cpu_cores jobs
    cpu_cores="$(get_cpu_cores)"
    jobs="$cpu_cores"
    printf '  Parallel static-content processes %s[%s]%s (%s cores detected): ' "$CYAN" "$jobs" "$RESET" "$cpu_cores"
    read -r input
    [[ -n "$input" ]] && jobs="$input"

    local retention="${LOG_RETENTION_DAYS:-30}"
    printf '  Log retention days %s[%s]%s (0 disables): ' "$CYAN" "$retention" "$RESET"
    read -r input
    [[ -n "$input" ]] && retention="$input"

    local healthcheck=""
    printf '  Health check URL %s[none]%s: ' "$CYAN" "$RESET"
    read -r input
    [[ -n "$input" ]] && healthcheck="$input"

    local config_path="$mage_dir/.deploy.env"
    echo
    echo "${BOLD}Configuration:${RESET}"
    echo "  Magento dir:      $mage_dir"
    echo "  PHP:              $php_bin (v$php_ver)"
    echo "  Composer:         $comp_bin"
    echo "  Frontend themes:  $themes_csv"
    echo "  Backend theme:    $backend_theme"
    echo "  Frontend langs:   $frontend_langs"
    echo "  Backend langs:    $backend_langs"
    echo "  Parallel jobs:    $jobs"
    echo "  Log retention:    $retention days"
    echo "  Health check:     ${healthcheck:-none}"
    echo

    local answer=""
    printf 'Write config to %s%s%s? [Y/n] ' "$CYAN" "$config_path" "$RESET"
    read -r answer
    if [[ "${answer:-y}" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi

    cat > "$config_path" << CONF
# Magento 2 deployment configuration
# Generated by: deploy.sh --init
# Date: $(date)

# Magento installation directory (absolute path)
MAGENTO_DIR=$mage_dir

# PHP binary path
PHP_BIN=$php_bin

# Composer binary path
COMPOSER_BIN=$comp_bin

# PHP memory_limit for CLI commands (-1 = unlimited)
PHP_MEMORY_LIMIT=-1

# Frontend themes (comma-separated)
FRONTEND_THEMES=$themes_csv

# Backend theme
BACKEND_THEME=$backend_theme

# Frontend locales (space-separated)
FRONTEND_LANGUAGES=$frontend_langs

# Backend locales (space-separated)
BACKEND_LANGUAGES=$backend_langs

# Parallel setup:static-content:deploy processes (one per theme+locale)
PARALLEL_JOBS=$jobs

# Extra options for every static-content:deploy process
#SCD_EXTRA_ARGS=--no-js-bundle

# Delete deploy logs/reports/backups older than N days (0 to disable)
LOG_RETENTION_DAYS=$retention

# setup:upgrade policy: auto (only on database changes), always, never
DB_UPGRADE=auto

# Maintenance policy: auto (only while setup:upgrade runs), always, never
MAINTENANCE=auto

# IPs allowed to browse the site during maintenance (comma/space separated)
#MAINTENANCE_ALLOWED_IPS=

# Reset OPcache right after the artifact swap - REQUIRED on hosts running
# php-fpm with opcache.validate_timestamps=0
#OPCACHE_RESET_CMD=sudo systemctl reload php8.3-fpm

# Storefront URL checked after the release (expects HTTP 2xx)
${healthcheck:+HEALTHCHECK_URL=$healthcheck}${healthcheck:-#HEALTHCHECK_URL=https://www.example.com/}

# Back up the database before setup:upgrade
#DB_BACKUP=true
#DB_BACKUP_CMD=

# Hook commands (run in the Magento directory)
#PRE_DEPLOY_CMD=git pull --ff-only
#POST_DEPLOY_CMD=

# Build directory (must be on the same filesystem as pub/ and generated/)
#BUILD_DIR=var/deploy

# Uncomment to skip specific steps by default:
#SKIP_COMPOSER=true
#SKIP_DB_CHECK=true
#SKIP_STATIC=true
#SKIP_DI_COMPILE=true
CONF

    echo
    echo "${GREEN}Config written to: $config_path${RESET}"
    echo "Run 'deploy.sh' to deploy with this configuration."
}

# ───────────────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────────────
main() {
    parse_arguments "$@"

    if [[ "$_RUN_INIT" == "true" ]]; then
        generate_config_wizard
        exit 0
    fi

    if [[ -z "$LOG_FILE" ]]; then
        if [[ -d "$MAGENTO_DIR" ]]; then
            LOG_FILE="$(cd "$MAGENTO_DIR" && pwd)/var/log/deploy_$(date +%Y%m%d_%H%M%S).log"
        else
            LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
        fi
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"

    clean_old_logs
    display_config

    DEPLOYMENT_START_TIME=$SECONDS
    DEPLOYMENT_STARTED=true
    _file_log INFO "Starting deployment (deploy.sh v$DEPLOY_VERSION, args: $*)"

    preflight
    run_pre_deploy_hook

    # Everything up to the release phase happens with the site online
    if [[ -n "$ARTIFACTS_DIR" ]]; then
        ui_phase "Composer" "skipped: releasing pre-built artifacts"
    else
        composer_phase
    fi

    if [[ "$BUILD_ONLY" == "true" ]]; then
        ui_phase "Database check" "skipped: --build-only"
    else
        database_check_phase
    fi

    # env.php only; the clone copies it, so the build sees the final mode
    [[ "$BUILD_ONLY" != "true" ]] && ensure_production_mode

    build_phase

    if [[ "$BUILD_ONLY" == "true" ]]; then
        push_artifacts
        local build_duration=$(( SECONDS - DEPLOYMENT_START_TIME ))
        generate_report "SUCCESS" "$build_duration"
        display_summary "SUCCESS" "$build_duration"
        [[ "$DRY_RUN" != "true" ]] && ui_kv "Artifacts" "$BUILD_ROOT (generated/, vendor/composer/, vendor/autoload.php, pub/static/, var/view_preprocessed/)"
        _file_log OK "Build completed in $(format_duration "$build_duration")"
        exit 0
    fi

    # Release: milliseconds of renames; maintenance only around setup:upgrade
    release_phase

    verify_phase
    run_post_deploy_hook

    local total_duration=$(( SECONDS - DEPLOYMENT_START_TIME ))
    generate_report "SUCCESS" "$total_duration"
    display_summary "SUCCESS" "$total_duration"
    _file_log OK "Deployment completed successfully in $(format_duration "$total_duration") (downtime $(format_duration "$DOWNTIME_SECONDS"))"
    exit 0
}

main "$@"

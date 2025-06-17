#!/bin/bash

# ===================================================================
# 🚀 MAGENTO 2 DEPLOYMENT SCRIPT
# ===================================================================

# Set strict mode - but allow for command failures we handle
set -uo pipefail

# Variables (adjust these as necessary)
MAGENTO_DIR="${MAGENTO_DIR:-./}" # Path to your Magento installation
PHP_BIN="${PHP_BIN:-php}"        # Path to PHP binary
COMPOSER_BIN="${COMPOSER_BIN:-/usr/local/bin/composer}" # Path to Composer binary
FRONTEND_THEMES=("Magento/luma") # Array of themes
BACKEND_THEME="Magento/backend"  # Backend theme
FRONTEND_LANGUAGES="en_GB"       # Array of languages
BACKEND_LANGUAGES="en_US en_GB"  # Array of languages

# Performance options
PARALLEL_JOBS="${PARALLEL_JOBS:-5}" # Number of parallel jobs for static content deployment
SKIP_COMPOSER="${SKIP_COMPOSER:-false}" # Skip composer install
SKIP_DB_CHECK="${SKIP_DB_CHECK:-false}" # Skip database check
VERBOSE="${VERBOSE:-false}" # Verbose output
DRY_RUN="${DRY_RUN:-false}" # Dry run mode
LOG_FILE="${LOG_FILE:-deployment_$(date +%Y%m%d_%H%M%S).log}" # Log file

# Colors and formatting
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
MAGENTA="\033[0;35m"
BG_BLUE="\033[44m"
BG_GREEN="\033[42m"
BG_RED="\033[41m"

# Progress spinner characters
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Display help
display_help() {
    cat << EOF
${BOLD}Magento 2 Deployment Script - Enhanced Version${RESET}

${BOLD}USAGE:${RESET}
    $0 [OPTIONS]

${BOLD}OPTIONS:${RESET}
    -h, --help              Show this help message
    -d, --dir PATH          Magento installation directory (default: current directory)
    -p, --php PATH          PHP binary path (default: php)
    -c, --composer PATH     Composer binary path (default: composer.phar)
    -j, --jobs NUM          Number of parallel jobs for static content (default: 5)
    --skip-composer         Skip composer install step
    --skip-db-check         Skip database upgrade check
    --dry-run               Run in dry-run mode (no actual changes)
    -v, --verbose           Enable verbose output
    --log FILE              Log file path (default: deployment_TIMESTAMP.log)
    --frontend-themes       Comma-separated list of frontend themes
    --backend-theme         Backend theme (default: Magento/backend)
    --frontend-langs        Comma-separated list of frontend languages
    --backend-langs         Comma-separated list of backend languages

${BOLD}EXAMPLES:${RESET}
    # Basic deployment
    $0

    # Deployment with custom directory and increased parallel jobs
    $0 -d /var/www/magento -j 8

    # Skip composer and use verbose mode
    $0 --skip-composer -v

    # Dry run to see what would be executed
    $0 --dry-run

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                display_help
                exit 0
                ;;
            -d|--dir)
                MAGENTO_DIR="$2"
                shift 2
                ;;
            -p|--php)
                PHP_BIN="$2"
                shift 2
                ;;
            -c|--composer)
                COMPOSER_BIN="$2"
                shift 2
                ;;
            -j|--jobs)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --skip-composer)
                SKIP_COMPOSER=true
                shift
                ;;
            --skip-db-check)
                SKIP_DB_CHECK=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --log)
                LOG_FILE="$2"
                shift 2
                ;;
            --frontend-themes)
                IFS=',' read -ra FRONTEND_THEMES <<< "$2"
                shift 2
                ;;
            --backend-theme)
                BACKEND_THEME="$2"
                shift 2
                ;;
            --frontend-langs)
                FRONTEND_LANGUAGES="$2"
                shift 2
                ;;
            --backend-langs)
                BACKEND_LANGUAGES="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                display_help
                exit 1
                ;;
        esac
    done
}

# Display banner
display_banner() {
    clear
    echo -e "${BG_BLUE}${BOLD}                                                                 ${RESET}"
    echo -e "${BG_BLUE}${BOLD}              MAGENTO 2 DEPLOYMENT TOOL - ENHANCED               ${RESET}"
    echo -e "${BG_BLUE}${BOLD}                                                                 ${RESET}"
    echo
}

# Log with timestamp and color
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local log_entry="[$timestamp] $level: $message"

    # Write to log file
    echo "$log_entry" >> "$LOG_FILE"

    # Display to console
    case $level in
        "INFO")
            echo -e "${CYAN}[${timestamp}]${RESET} ${BLUE}ℹ️  INFO:${RESET} $message"
            ;;
        "SUCCESS")
            echo -e "${CYAN}[${timestamp}]${RESET} ${GREEN}✅ SUCCESS:${RESET} $message"
            ;;
        "WARNING")
            echo -e "${CYAN}[${timestamp}]${RESET} ${YELLOW}⚠️  WARNING:${RESET} $message"
            ;;
        "ERROR")
            echo -e "${CYAN}[${timestamp}]${RESET} ${RED}❌ ERROR:${RESET} $message"
            ;;
        "STEP")
            echo
            echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
            echo -e "${CYAN}[${timestamp}]${RESET} ${BG_GREEN}${BOLD} STEP ${RESET} ${BOLD}$message${RESET}"
            echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
            ;;
        "DEBUG")
            if [ "$VERBOSE" = true ]; then
                echo -e "${CYAN}[${timestamp}]${RESET} ${MAGENTA}🔍 DEBUG:${RESET} $message"
            fi
            ;;
    esac
}

# Show a command being executed with spinner
show_spinner() {
    local pid=$1
    local message=$2
    local i=0

    echo -ne "${YELLOW}${SPINNER[0]}${RESET} $message"

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#SPINNER[@]} ))
        echo -ne "\r${YELLOW}${SPINNER[$i]}${RESET} $message"
        sleep 0.1
    done

    wait $pid
    local exit_status=$?

    if [ $exit_status -eq 0 ]; then
        echo -e "\r${GREEN}✓${RESET} $message ${GREEN}(Done)${RESET}"
    else
        echo -e "\r${RED}✗${RESET} $message ${RED}(Failed with exit code: $exit_status)${RESET}"
    fi

    return $exit_status
}

# Track deployment state
DEPLOYMENT_STATE_FILE="/tmp/.magento_deployment_state_$$"
MAINTENANCE_ENABLED=false
ORIGINAL_MODE=""

# Save deployment state
save_deployment_state() {
    cat > "$DEPLOYMENT_STATE_FILE" << EOF
MAINTENANCE_ENABLED=$MAINTENANCE_ENABLED
ORIGINAL_MODE=$ORIGINAL_MODE
MAGENTO_DIR=$MAGENTO_DIR
PHP_BIN=$PHP_BIN
EOF
}

# Load deployment state
load_deployment_state() {
    if [ -f "$DEPLOYMENT_STATE_FILE" ]; then
        source "$DEPLOYMENT_STATE_FILE"
    fi
}

# Add trap for Ctrl+C and other termination signals
cleanup() {
    local exit_code=$?
    echo
    log_message "WARNING" "Deployment interrupted! (Exit code: $exit_code)"
    log_message "INFO" "Performing cleanup..."

    load_deployment_state

    # Check if maintenance mode was enabled by this script
    if [ "$MAINTENANCE_ENABLED" = true ]; then
        log_message "INFO" "Disabling maintenance mode before exit..."
        if [ "$DRY_RUN" != true ]; then
            $PHP_BIN $MAGENTO_DIR/bin/magento maintenance:disable 2>/dev/null || log_message "ERROR" "Failed to disable maintenance mode!"
        fi
    fi

    # Restore original mode if changed
    if [ -n "$ORIGINAL_MODE" ] && [ "$ORIGINAL_MODE" != "production" ]; then
        log_message "INFO" "Restoring original mode: $ORIGINAL_MODE"
        if [ "$DRY_RUN" != true ]; then
            $PHP_BIN $MAGENTO_DIR/bin/magento deploy:mode:set "$ORIGINAL_MODE" --skip-compilation 2>/dev/null || log_message "ERROR" "Failed to restore mode!"
        fi
    fi

    # Remove state file
    rm -f "$DEPLOYMENT_STATE_FILE"

    log_message "INFO" "Cleanup complete. Check log file: $LOG_FILE"
    exit $exit_code
}

# Set up trap for common termination signals
trap cleanup SIGINT SIGTERM SIGHUP EXIT

# Run command with progress display
run_command() {
    local command="$1"
    local message="$2"
    local show_output=${3:-false}
    local ignore_warnings=${4:-true}

    log_message "DEBUG" "Executing: $command"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${RESET} Would execute: $message"
        return 0
    fi

    if [ "$show_output" = true ] || [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}┌─ Command Output ───────────────────────────────────────────────────────┐${RESET}"
        echo -e "${YELLOW}⚙${RESET} $message"

        local output_file=$(mktemp)
        local error_file=$(mktemp)

        # Execute command and capture both stdout and stderr
        if script -q -c "$command" /dev/null > "$output_file" 2> "$error_file"; then
            local result=0
        else
            local result=$?
        fi

        # Display output
        cat "$output_file"
        if [ -s "$error_file" ]; then
            echo -e "${RED}=== Errors ===${RESET}"
            cat "$error_file"
        fi

        # Log all output
        cat "$output_file" >> "$LOG_FILE"
        cat "$error_file" >> "$LOG_FILE"

        echo -e "${CYAN}└────────────────────────────────────────────────────────────────────────┘${RESET}"

        # Check for PHP warnings/errors in output
        local has_php_errors=false
        if grep -qiE "(warning|error|fatal|exception|failed to open stream)" "$output_file" "$error_file" 2>/dev/null; then
            has_php_errors=true
        fi

        # Determine success/failure
        if [ $result -eq 0 ] && { [ "$ignore_warnings" = true ] || [ "$has_php_errors" = false ]; }; then
            echo -e "${GREEN}✓${RESET} $message ${GREEN}(Done)${RESET}"
        elif [ $result -eq 0 ] && [ "$has_php_errors" = true ] && [ "$ignore_warnings" = false ]; then
            echo -e "${YELLOW}⚠${RESET} $message ${YELLOW}(Completed with warnings)${RESET}"
            log_message "WARNING" "Command completed with warnings"
            result=1  # Convert to failure
        else
            echo -e "${RED}✗${RESET} $message ${RED}(Failed with exit code: $result)${RESET}"
            log_message "ERROR" "Command failed with exit code: $result"
        fi

        rm -f "$output_file" "$error_file"
        return $result
    else
        local output_file=$(mktemp)
        local error_occurred=false

        # Start command in background
        eval "$command" > "$output_file" 2>&1 &
        local command_pid=$!

        # Show spinner while command runs
        show_spinner $command_pid "$message"
        local result=$?

        # Check for PHP warnings/errors even in non-verbose mode
        if [ $result -eq 0 ] && [ "$ignore_warnings" = false ]; then
            if grep -qiE "(warning|error|fatal|exception|failed to open stream)" "$output_file" 2>/dev/null; then
                result=1
                error_occurred=true
                log_message "WARNING" "Command completed with warnings/errors:"
                grep -iE "(warning|error|fatal|exception|failed to open stream)" "$output_file" | head -10 >> "$LOG_FILE"
            fi
        fi

        if [ $result -ne 0 ] || [ "$error_occurred" = true ]; then
            log_message "ERROR" "Command failed. Full output:"
            echo -e "${CYAN}──── Command Output ────────────────────────────────────────────────────${RESET}"
            cat "$output_file"
            echo -e "${CYAN}────────────────────────────────────────────────────────────────────────${RESET}"
            cat "$output_file" >> "$LOG_FILE"
        else
            # Still log output to file even if successful
            cat "$output_file" >> "$LOG_FILE"
        fi

        rm -f "$output_file"
        return $result
    fi
}

# Display duration in human-readable format
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Check system requirements
check_system_requirements() {
    log_message "STEP" "Checking System Requirements"
    local start_time=$SECONDS
    local has_errors=false

    # Check available disk space
    local available_space=$(df -BG "$MAGENTO_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_space" -lt 5 ]; then
        log_message "WARNING" "Low disk space: ${available_space}GB available (recommend at least 5GB)"
    else
        log_message "INFO" "Disk space: ${available_space}GB available"
    fi

    # Check available memory
    local total_mem=$(free -m | awk 'NR==2 {print $2}')
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_mem" -lt 2048 ]; then
        log_message "WARNING" "Low memory: ${available_mem}MB available (recommend at least 2GB)"
    else
        log_message "INFO" "Memory: ${available_mem}MB available of ${total_mem}MB total"
    fi

    # Check CPU cores for parallel processing
    local cpu_cores=$(nproc)
    log_message "INFO" "CPU cores available: $cpu_cores"

    # Adjust parallel jobs based on available resources
    if [ "$cpu_cores" -lt "$PARALLEL_JOBS" ]; then
        log_message "WARNING" "Reducing parallel jobs from $PARALLEL_JOBS to $cpu_cores based on CPU cores"
        PARALLEL_JOBS=$cpu_cores
    fi

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "System requirements check completed in $(format_duration $duration)"
}

# Get current Magento mode
get_current_mode() {
    if [ -f "$MAGENTO_DIR/bin/magento" ]; then
        local mode=$($PHP_BIN $MAGENTO_DIR/bin/magento deploy:mode:show 2>/dev/null | grep -oP 'Current application mode: \K\w+' || echo "")
        echo "$mode"
    fi
}

# Functions
function enable_maintenance {
    log_message "STEP" "Enabling Maintenance Mode"
    local start_time=$SECONDS

    log_message "DEBUG" "Running maintenance:enable command"
    run_command "$PHP_BIN $MAGENTO_DIR/bin/magento maintenance:enable" "Enabling maintenance mode"
    local result=$?

    log_message "DEBUG" "maintenance:enable returned exit code: $result"

    if [ $result -ne 0 ]; then
        log_message "ERROR" "Failed to enable maintenance mode (exit code: $result)"

        # Try to get more information about the failure
        echo -e "${YELLOW}Attempting to diagnose the issue...${RESET}"

        # Check if bin/magento is executable
        if [ ! -x "$MAGENTO_DIR/bin/magento" ]; then
            log_message "ERROR" "bin/magento is not executable"
            echo -e "${RED}Error: bin/magento is not executable. Run: chmod +x $MAGENTO_DIR/bin/magento${RESET}"
        fi

        # Check if PHP can run the script
        echo -e "${CYAN}Testing PHP execution...${RESET}"
        $PHP_BIN -v

        # Try running the command directly to see the actual error
        echo -e "${CYAN}Direct command output:${RESET}"
        $PHP_BIN $MAGENTO_DIR/bin/magento maintenance:enable 2>&1 || true

        exit 1
    fi

    MAINTENANCE_ENABLED=true
    save_deployment_state

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Maintenance mode enabled in $(format_duration $duration)"
}

function attemptCommand() {
    local command=$1
    local max_attempts=$2
    local error_message=$3
    local message=$4
    local show_output=${5:-false}
    local attempts=0
    local start_time=$SECONDS

    log_message "INFO" "Attempting command: $message"

    while [ $attempts -lt $max_attempts ]; do
        ((attempts++))

        echo -e "${YELLOW}⚙${RESET} $message ${YELLOW}(Attempt $attempts/$max_attempts)${RESET}"
        local output_file=$(mktemp)
        local error_file=$(mktemp)

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN]${RESET} Would execute: $command"
            rm -f "$output_file" "$error_file"
            return 0
        fi

        if [ "$show_output" = true ] || [ "$VERBOSE" = true ]; then
            echo -e "${CYAN}┌─ Command Output ───────────────────────────────────────────────────────┐${RESET}"
            script -q -c "$command" /dev/null 2>"$error_file" | tee "$output_file"
            local result=${PIPESTATUS[0]}
            echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${RESET}"
        else
            local i=0
            echo -ne "${YELLOW}${SPINNER[0]}${RESET} Working..."

            eval "$command" > "$output_file" 2>"$error_file" &
            local cmd_pid=$!

            while kill -0 $cmd_pid 2>/dev/null; do
                i=$(( (i+1) % ${#SPINNER[@]} ))
                echo -ne "\r${YELLOW}${SPINNER[$i]}${RESET} Working..."
                sleep 0.1
            done

            wait $cmd_pid
            local result=$?
            echo -ne "\r                      \r"
        fi

        # Log command output
        cat "$output_file" >> "$LOG_FILE"
        cat "$error_file" >> "$LOG_FILE"

        # Check for PHP warnings/errors
        local has_critical_errors=false
        if grep -qiE "(fatal|exception|error:|parse error)" "$output_file" "$error_file" 2>/dev/null; then
            has_critical_errors=true
        fi

        # Success criteria: command returns 0, no specified error message, and no critical PHP errors
        if [ $result -eq 0 ] && ! grep -q "$error_message" "$output_file" "$error_file" 2>/dev/null && [ "$has_critical_errors" = false ]; then
            echo -e "${GREEN}✓${RESET} $message ${GREEN}(Succeeded on attempt $attempts)${RESET}"
            rm -f "$output_file" "$error_file"

            local duration=$((SECONDS - start_time))
            log_message "SUCCESS" "Command completed in $(format_duration $duration)"
            return 0
        else
            echo -e "${YELLOW}⚠${RESET} $message ${YELLOW}(Attempt $attempts failed)${RESET}"

            if [ "$show_output" != true ] && [ "$VERBOSE" != true ]; then
                echo -e "${CYAN}──── Error Output ────────────────────────────────────────────────────────${RESET}"
                # Show both stdout and stderr
                if [ -s "$output_file" ]; then
                    echo "=== Standard Output ==="
                    tail -n 20 "$output_file"
                fi
                if [ -s "$error_file" ]; then
                    echo "=== Error Output ==="
                    tail -n 20 "$error_file"
                fi
                echo -e "${CYAN}────────────────────────────────────────────────────────────────────────${RESET}"
            fi

            if [ $attempts -lt $max_attempts ]; then
                log_message "WARNING" "Retrying in 2 seconds..."
                sleep 2
            fi
        fi

        rm -f "$output_file" "$error_file"
    done

    echo -e "${RED}✗${RESET} $message ${RED}(Failed after $max_attempts attempts)${RESET}"
    log_message "ERROR" "Failed to run the command after $max_attempts attempts."
    local duration=$((SECONDS - start_time))
    log_message "INFO" "Operation took $(format_duration $duration)"
    return 1
}

function enable_developer_mode() {
    log_message "STEP" "Enabling Developer Mode"
    local start_time=$SECONDS

    # Store original mode
    ORIGINAL_MODE=$(get_current_mode)
    save_deployment_state

    # First, try to flush cache but don't fail if there are warnings
    log_message "INFO" "Attempting to flush cache before mode change..."
    run_command "$PHP_BIN bin/magento cache:flush" "Flushing cache" true true

    # If we have missing generated files, we might need to handle this differently
    if [ -d "$MAGENTO_DIR/generated" ]; then
        log_message "INFO" "Cleaning generated files before mode switch..."
        run_command "rm -rf $MAGENTO_DIR/generated/code/* $MAGENTO_DIR/generated/metadata/*" "Cleaning generated files"
    fi

    # Now attempt to set developer mode
    attemptCommand "${PHP_BIN} ${MAGENTO_DIR}/bin/magento deploy:mode:set developer" 5 "Directory not empty" "Setting developer mode"

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to enable developer mode. Exiting."
        exit 1
    fi

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Developer mode enabled in $(format_duration $duration)"
}

function enable_production_mode() {
    log_message "STEP" "Enabling Production Mode"
    local start_time=$SECONDS

    run_command "$PHP_BIN $MAGENTO_DIR/bin/magento deploy:mode:set production --skip-compilation" "Setting production mode"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to enable production mode. Exiting."
        exit 1
    fi

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Production mode enabled in $(format_duration $duration)"
}

function disable_maintenance {
    log_message "STEP" "Disabling Maintenance Mode"
    local start_time=$SECONDS

    run_command "$PHP_BIN $MAGENTO_DIR/bin/magento maintenance:disable" "Disabling maintenance mode"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to disable maintenance mode. Exiting."
        exit 1
    fi

    MAINTENANCE_ENABLED=false
    save_deployment_state

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Maintenance mode disabled in $(format_duration $duration)"
}

function composer_install {
    if [ "$SKIP_COMPOSER" = true ]; then
        log_message "INFO" "Skipping composer install (--skip-composer flag set)"
        return 0
    fi

    log_message "STEP" "Running Composer Install"
    local start_time=$SECONDS

    cd $MAGENTO_DIR || exit

    # Check if composer.lock exists
    if [ ! -f "composer.lock" ]; then
        log_message "WARNING" "composer.lock not found. Running composer update instead."
        # Don't use --optimize-autoloader here as it interferes with setup:di:compile
        run_command "$PHP_BIN $COMPOSER_BIN update --no-dev" "Updating Composer dependencies" true
    else
        # Don't use --optimize-autoloader here as it interferes with setup:di:compile
        run_command "$PHP_BIN $COMPOSER_BIN install --no-dev" "Installing Composer dependencies" true
    fi

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Composer install failed. Exiting."
        exit 1
    fi

    log_message "INFO" "Note: Autoloader optimization will be done after DI compilation"

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Composer install completed in $(format_duration $duration)"
}

function check_and_upgrade_db {
    if [ "$SKIP_DB_CHECK" = true ]; then
        log_message "INFO" "Skipping database check (--skip-db-check flag set)"
        return 0
    fi

    log_message "STEP" "Checking Database Status"
    local start_time=$SECONDS

    log_message "INFO" "Checking if database upgrade is needed..."
    local databaseUpgradeNeeded=false

    echo -e "${CYAN}┌─ Database Status Check ─────────────────────────────────────────────────┐${RESET}"
    $PHP_BIN $MAGENTO_DIR/bin/magento setup:db:status 2>&1 | tee -a "$LOG_FILE"
    local db_status=${PIPESTATUS[0]}
    echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${RESET}"

    if [ $db_status -ne 0 ]; then
        databaseUpgradeNeeded=true
        log_message "INFO" "Database upgrade needed."
    else
        log_message "INFO" "Database is already up-to-date."
    fi

    if [ "$databaseUpgradeNeeded" = true ]; then
        enable_maintenance
        run_command "$PHP_BIN $MAGENTO_DIR/bin/magento setup:upgrade --keep-generated --no-interaction" "Upgrading database schema" true
        disable_maintenance
    fi

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Database check completed in $(format_duration $duration)"
}

function magento_commands {
    log_message "STEP" "Running Magento Setup Commands"
    local start_time=$SECONDS

    cd $MAGENTO_DIR || exit

    # IMPORTANT: DI compilation must be done BEFORE optimizing the autoloader
    log_message "INFO" "Starting DI compilation..."
    log_message "INFO" "Note: Running without optimized autoloader to ensure proper compilation"

    attemptCommand "${PHP_BIN} bin/magento setup:di:compile" 5 "Directory not empty" "Compiling dependency injection code" true

    if [ $? -ne 0 ]; then
        log_message "ERROR" "DI compilation failed. Check the output above for details."
        exit 1
    fi

    # NOW optimize the autoloader after DI compilation is complete
    composer_dump_autoload

    # Static content deployment with optimizations
    deploy_static_content

    # Flush all caches
    run_command "$PHP_BIN bin/magento cache:flush" "Flushing all caches"

    check_and_upgrade_db

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Magento setup commands completed in $(format_duration $duration)"
}

function deploy_static_content() {
    log_message "INFO" "Deploying static content with optimizations..."

    # Create deployment strategy based on themes
    local frontend_themes_count=${#FRONTEND_THEMES[@]}
    local total_themes=$((frontend_themes_count + 1)) # +1 for backend
    local jobs_per_theme=$((PARALLEL_JOBS / total_themes))

    if [ $jobs_per_theme -lt 1 ]; then
        jobs_per_theme=1
    fi

    log_message "INFO" "Deploying $total_themes themes with $jobs_per_theme jobs per theme"

    # Deploy frontend themes
    if [ ${#FRONTEND_THEMES[@]} -gt 0 ]; then
        theme_args=""
        for theme in "${FRONTEND_THEMES[@]}"; do
            theme_args+=" --theme=$theme"
        done

        log_message "INFO" "Deploying frontend themes: ${FRONTEND_THEMES[*]}"
        echo -e "${CYAN}┌─ Frontend Theme Static Content Deployment ────────────────────────────┐${RESET}"

        if [ "$DRY_RUN" != true ]; then
            $PHP_BIN bin/magento setup:static-content:deploy \
                $theme_args \
                --no-parent \
                -j$jobs_per_theme \
                --max-execution-time=3600 \
                --force \
                $FRONTEND_LANGUAGES 2>&1 | tee -a "$LOG_FILE"
            local frontend_exit=${PIPESTATUS[0]}
        else
            echo "[DRY RUN] Would deploy frontend themes"
            local frontend_exit=0
        fi

        echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${RESET}"

        if [ $frontend_exit -eq 0 ]; then
            log_message "SUCCESS" "Frontend themes deployed successfully"
        else
            log_message "ERROR" "Frontend themes deployment failed"
        fi
    fi

    # Deploy backend theme
    log_message "INFO" "Deploying backend theme: $BACKEND_THEME"
    echo -e "${CYAN}┌─ Backend Theme Static Content Deployment ─────────────────────────────┐${RESET}"

    if [ "$DRY_RUN" != true ]; then
        $PHP_BIN bin/magento setup:static-content:deploy \
            --theme=$BACKEND_THEME \
            --no-parent \
            -j$jobs_per_theme \
            --max-execution-time=3600 \
            --force \
            $BACKEND_LANGUAGES 2>&1 | tee -a "$LOG_FILE"
        local backend_exit=${PIPESTATUS[0]}
    else
        echo "[DRY RUN] Would deploy backend theme"
        local backend_exit=0
    fi

    echo -e "${CYAN}└───────────────────────────────────────────────────────────────────────┘${RESET}"

    if [ $backend_exit -eq 0 ]; then
        log_message "SUCCESS" "Backend theme deployed successfully"
    else
        log_message "ERROR" "Backend theme deployment failed"
    fi
}

function composer_dump_autoload {
    log_message "STEP" "Optimizing Autoloader"
    local start_time=$SECONDS

    cd $MAGENTO_DIR || exit

    log_message "INFO" "Running composer dump-autoload with optimization after DI compilation"

    # First try with APCu optimization
    run_command "$PHP_BIN $COMPOSER_BIN dump-autoload --optimize --apcu" "Optimizing Composer autoloader with APCu"
    if [ $? -ne 0 ]; then
        log_message "WARNING" "APCu optimization failed, falling back to standard optimization"
        run_command "$PHP_BIN $COMPOSER_BIN dump-autoload --optimize" "Optimizing Composer autoloader"

        if [ $? -ne 0 ]; then
            log_message "ERROR" "Composer dump-autoload failed. Exiting."
            exit 1
        fi
    fi

    local duration=$((SECONDS - start_time))
    log_message "SUCCESS" "Composer autoload optimization completed in $(format_duration $duration)"
}

function post_deployment_checks() {
    log_message "STEP" "Running Post-Deployment Checks"
    local start_time=$SECONDS
    local has_errors=false

    # Check generated files
    local generated_dirs=("generated/code" "generated/metadata" "pub/static" "var/view_preprocessed")
    for dir in "${generated_dirs[@]}"; do
        if [ -d "$MAGENTO_DIR/$dir" ]; then
            local file_count=$(find "$MAGENTO_DIR/$dir" -type f | wc -l)
            log_message "INFO" "$dir contains $file_count files"
        else
            log_message "WARNING" "$dir directory not found"
            has_errors=true
        fi
    done

    # Check deployment log for errors
    local deployment_errors=$(grep -c "ERROR" "$LOG_FILE" || true)
    if [ $deployment_errors -gt 0 ]; then
        log_message "WARNING" "Found $deployment_errors errors during deployment"
        has_errors=true
    fi

    local duration=$((SECONDS - start_time))
    if [ "$has_errors" = true ]; then
        log_message "WARNING" "Post-deployment checks completed with warnings in $(format_duration $duration)"
    else
        log_message "SUCCESS" "All post-deployment checks passed in $(format_duration $duration)"
    fi
}

function generate_deployment_report() {
    log_message "INFO" "Generating deployment report..."

    local report_file="deployment_report_$(date +%Y%m%d_%H%M%S).txt"

    cat > "$report_file" << EOF
================================================================================
                         MAGENTO 2 DEPLOYMENT REPORT
================================================================================
Date: $(date)
Duration: $(format_duration $total_duration)
Status: ${deployment_status:-COMPLETED}

CONFIGURATION:
- Magento Directory: $MAGENTO_DIR
- PHP Version: $($PHP_BIN -v | head -n1)
- Composer Version: $($PHP_BIN $COMPOSER_BIN --version 2>/dev/null | head -n1 || echo "N/A")
- Frontend Themes: ${FRONTEND_THEMES[*]}
- Backend Theme: $BACKEND_THEME
- Parallel Jobs: $PARALLEL_JOBS

DEPLOYMENT STEPS:
$(grep "STEP" "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g')

ERRORS AND WARNINGS:
$(grep -E "(ERROR|WARNING)" "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g' || echo "None")

SYSTEM RESOURCES:
- Disk Usage: $(df -h "$MAGENTO_DIR" | awk 'NR==2 {print $5}')
- Memory Usage: $(free -h | awk 'NR==2 {printf "%.1f%% of %s", $3/$2*100, $2}')

RECOMMENDATIONS:
EOF

    # Add recommendations based on deployment
    if grep -q "ERROR" "$LOG_FILE"; then
        echo "- Review and fix errors found during deployment" >> "$report_file"
    fi

    if grep -q "Low memory" "$LOG_FILE"; then
        echo "- Consider increasing server memory for better performance" >> "$report_file"
    fi

    if [ "$PARALLEL_JOBS" -lt 4 ]; then
        echo "- Consider using more parallel jobs if CPU allows" >> "$report_file"
    fi

    echo "" >> "$report_file"
    echo "Full deployment log: $LOG_FILE" >> "$report_file"
    echo "=================================================================================" >> "$report_file"

    log_message "SUCCESS" "Deployment report generated: $report_file"
}

function validate_variables {
    log_message "STEP" "Validating Configuration"
    local start_time=$SECONDS
    local errors_found=false

    # Convert MAGENTO_DIR to absolute path
    MAGENTO_DIR=$(cd "$MAGENTO_DIR" 2>/dev/null && pwd || echo "$MAGENTO_DIR")

    # Check if MAGENTO_DIR exists and is a directory
    if [ ! -d "$MAGENTO_DIR" ]; then
        log_message "ERROR" "Magento directory not found: $MAGENTO_DIR"
        errors_found=true
    else
        log_message "INFO" "Magento directory exists: $MAGENTO_DIR"

        # Check for key Magento files
        local required_files=("app/etc/env.php" "bin/magento" "composer.json")
        for file in "${required_files[@]}"; do
            if [ ! -f "$MAGENTO_DIR/$file" ]; then
                log_message "ERROR" "Required file not found: $file"
                errors_found=true
            else
                log_message "DEBUG" "Found required file: $file"
            fi
        done
    fi

    # Check if PHP is installed and accessible
    if ! command -v $PHP_BIN &> /dev/null; then
        log_message "ERROR" "PHP binary not found: $PHP_BIN"
        errors_found=true
    else
        PHP_VERSION=$($PHP_BIN -r 'echo PHP_VERSION;')
        log_message "INFO" "PHP found: version $PHP_VERSION"

        # Extract required PHP version from composer.json
        if [ -f "$MAGENTO_DIR/composer.json" ]; then
            PHP_REQUIRED=$($PHP_BIN -r "
                \$composer = json_decode(file_get_contents('$MAGENTO_DIR/composer.json'), true);
                \$requirement = \$composer['require']['php'] ?? '>=7.4';
                echo \$requirement;
            ")
            log_message "INFO" "Magento requires PHP: $PHP_REQUIRED"

            # Check PHP version compatibility
            PHP_VERSION_CHECK=$($PHP_BIN -r "
                \$current = PHP_VERSION;
                \$constraint = '$PHP_REQUIRED';
                // Simple version check - for production use, consider using composer/semver
                if (strpos(\$constraint, '~') === 0 || strpos(\$constraint, '^') === 0) {
                    \$constraint = substr(\$constraint, 1);
                }
                \$constraint = str_replace('>=', '', \$constraint);
                \$constraint = str_replace('>', '', \$constraint);
                \$constraint = trim(\$constraint);

                if (version_compare(\$current, \$constraint, '>=')) {
                    echo 'OK';
                    exit(0);
                } else {
                    echo 'ERROR: PHP ' . \$constraint . ' or later required, but found ' . \$current;
                    exit(1);
                }
            ")

            if [ $? -ne 0 ]; then
                log_message "ERROR" "$PHP_VERSION_CHECK"
                errors_found=true
            else
                log_message "SUCCESS" "PHP version is compatible"
            fi
        fi

        # Check for required PHP extensions
        REQUIRED_EXTENSIONS=("bcmath" "ctype" "curl" "dom" "gd" "hash" "iconv" "intl" "json" "mbstring" "openssl" "pdo_mysql" "simplexml" "soap" "xsl" "zip" "sockets")
        MISSING_EXTENSIONS=()

        for ext in "${REQUIRED_EXTENSIONS[@]}"; do
            if ! $PHP_BIN -m | grep -qi "^$ext$"; then
                MISSING_EXTENSIONS+=("$ext")
            fi
        done

        if [ ${#MISSING_EXTENSIONS[@]} -gt 0 ]; then
            log_message "ERROR" "Missing required PHP extensions: ${MISSING_EXTENSIONS[*]}"
            errors_found=true
        else
            log_message "INFO" "All required PHP extensions are available"
        fi

        # Check optional but recommended extensions
        OPTIONAL_EXTENSIONS=("redis" "apcu" "opcache")
        for ext in "${OPTIONAL_EXTENSIONS[@]}"; do
            if ! $PHP_BIN -m | grep -qi "^$ext$"; then
                log_message "WARNING" "Optional extension not found: $ext (recommended for performance)"
            fi
        done
    fi

    # Check if Composer binary is accessible
    local composer_path="$COMPOSER_BIN"
    if [ ! -f "$COMPOSER_BIN" ]; then
        if [ -f "$MAGENTO_DIR/$COMPOSER_BIN" ]; then
            composer_path="$MAGENTO_DIR/$COMPOSER_BIN"
            COMPOSER_BIN="$composer_path"
        elif command -v composer &> /dev/null; then
            composer_path="composer"
            COMPOSER_BIN="composer"
            log_message "INFO" "Using system composer"
        else
            log_message "ERROR" "Composer binary not found: $COMPOSER_BIN"
            errors_found=true
        fi
    fi

    if [ -n "$composer_path" ] && ([ -f "$composer_path" ] || command -v "$composer_path" &> /dev/null); then
        COMPOSER_VERSION=$($PHP_BIN $composer_path --version 2>/dev/null | head -n 1 || echo "")
        if [ -n "$COMPOSER_VERSION" ]; then
            log_message "INFO" "Composer found: $COMPOSER_VERSION"
        fi
    fi

    # Validate themes
    log_message "INFO" "Validating configured themes..."

    # Check frontend themes
    for theme in "${FRONTEND_THEMES[@]}"; do
        log_message "INFO" "Checking frontend theme: $theme"
        # Themes might be in app/design, vendor, or installed via composer
        # So we just log them for now
    done

    # Check backend theme
    log_message "INFO" "Backend theme configured: $BACKEND_THEME"

    # Check if any errors were found
    if [ "$errors_found" = true ]; then
        log_message "ERROR" "Configuration validation failed. Please fix the errors above before continuing."

        if [ "$DRY_RUN" != true ]; then
            echo -e "${YELLOW}Would you like to continue anyway? (y/N)${RESET}"
            read -r continue_anyway
            if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                log_message "INFO" "Deployment aborted by user."
                exit 1
            else
                log_message "WARNING" "Continuing with deployment despite validation errors."
            fi
        fi
    else
        local duration=$((SECONDS - start_time))
        log_message "SUCCESS" "All configuration variables validated successfully in $(format_duration $duration)"
    fi
}

# Create deployment summary
create_deployment_summary() {
    local status=$1
    local duration=$2

    echo
    if [ "$status" = "SUCCESS" ]; then
        echo -e "${BG_GREEN}${BOLD}                                                                 ${RESET}"
        echo -e "${BG_GREEN}${BOLD}                   DEPLOYMENT COMPLETE                           ${RESET}"
        echo -e "${BG_GREEN}${BOLD}                                                                 ${RESET}"
    else
        echo -e "${BG_RED}${BOLD}                                                                 ${RESET}"
        echo -e "${BG_RED}${BOLD}                   DEPLOYMENT FAILED                             ${RESET}"
        echo -e "${BG_RED}${BOLD}                                                                 ${RESET}"
    fi
    echo

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}Deployment Summary:${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${BLUE}Duration:${RESET} $(format_duration $duration)"
    echo -e "  ${BLUE}Log file:${RESET} $LOG_FILE"
    echo -e "  ${BLUE}Mode:${RESET} $(get_current_mode)"

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}Mode:${RESET} DRY RUN - No actual changes were made"
    fi


    local error_count=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
    local warning_count=$(grep -c "WARNING" "$LOG_FILE" 2>/dev/null || echo 0)

    if [ "$error_count" -gt 0 ] 2>/dev/null; then
        echo -e "  ${RED}Errors:${RESET} $error_count"
    fi

    if [ "$warning_count" -gt 0 ]; then
        echo -e "  ${YELLOW}Warnings:${RESET} $warning_count"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Main script execution
main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Display banner
    display_banner

    # Initialize deployment
    total_start_time=$SECONDS
    deployment_status="FAILED"

    log_message "STEP" "Starting Magento 2 Deployment"
    echo -e "${YELLOW}🔍 Deployment Configuration:${RESET}"
    echo -e "  ${CYAN}•${RESET} Magento directory: ${MAGENTO_DIR}"
    echo -e "  ${CYAN}•${RESET} PHP binary: ${PHP_BIN}"
    echo -e "  ${CYAN}•${RESET} Frontend themes: ${FRONTEND_THEMES[*]}"
    echo -e "  ${CYAN}•${RESET} Backend theme: ${BACKEND_THEME}"
    echo -e "  ${CYAN}•${RESET} Frontend languages: ${FRONTEND_LANGUAGES}"
    echo -e "  ${CYAN}•${RESET} Backend languages: ${BACKEND_LANGUAGES}"
    echo -e "  ${CYAN}•${RESET} Parallel jobs: ${PARALLEL_JOBS}"
    echo -e "  ${CYAN}•${RESET} Log file: ${LOG_FILE}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}•${RESET} Mode: ${YELLOW}DRY RUN${RESET}"
    fi
    echo

    # Run deployment steps
    validate_variables
    check_system_requirements

    # Store initial state
    ORIGINAL_MODE=$(get_current_mode)
    save_deployment_state

    # Main deployment sequence
    enable_maintenance

    if [ "$SKIP_COMPOSER" != true ]; then
        composer_install
    fi

    enable_developer_mode
    enable_production_mode
    magento_commands
    # Note: composer_dump_autoload is now called from within magento_commands after DI compilation
    disable_maintenance

    # Post-deployment
    post_deployment_checks

    deployment_status="SUCCESS"
    total_duration=$((SECONDS - total_start_time))

    # Generate report
    generate_deployment_report

    # Show summary
    create_deployment_summary "$deployment_status" "$total_duration"

    # Cleanup
    rm -f "$DEPLOYMENT_STATE_FILE"
    trap - EXIT

    if [ "$deployment_status" = "SUCCESS" ]; then
        log_message "SUCCESS" "Magento 2 deployment completed successfully!"
        exit 0
    else
        log_message "ERROR" "Magento 2 deployment failed!"
        exit 1
    fi
}

# Execute main function
main "$@"

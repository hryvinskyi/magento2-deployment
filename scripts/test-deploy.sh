#!/bin/bash
# ===================================================================
# Test harness for deploy.sh
# ===================================================================
# Runs deployment scenarios against a throwaway sandbox Magento tree
# using stub php/curl/mysqldump binaries - it never touches a real
# store, database, or network. Works on macOS (bash 3.2, no flock)
# and Linux (flock available).
#
# Usage: bash scripts/test-deploy.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$REPO_ROOT/deploy.sh"
BASH_BIN="/bin/bash"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")" || exit 1
SANDBOX="$WORK/sandbox"
STUBBIN="$WORK/bin"
FAKEPHP="$STUBBIN/fakephp"
FAKECOMPOSER="$WORK/fakecomposer.phar"
FAKE_LOG_FILE="$WORK/fake.log"
OUT="$WORK/out.txt"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$STUBBIN"

HOLDER=""
harness_cleanup() {
    if [[ -n "$HOLDER" ]]; then
        pkill -P "$HOLDER" 2>/dev/null
        kill "$HOLDER" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap harness_cleanup EXIT

# ── Stub binaries ──────────────────────────────────────────────────

# Fake PHP: records invocations and simulates bin/magento relative to
# the root the invoked bin/magento lives in (live tree or build clone).
cat > "$FAKEPHP" <<'STUB'
#!/bin/bash
[[ -n "${FAKE_LOG:-}" ]] && echo "PHP $*" >> "$FAKE_LOG"

while [[ "${1:-}" == "-d" ]]; do shift 2; done

case "${1:-}" in
    -r)
        if [[ "${2:-}" == *env.php* ]]; then
            printf '%s\n' "fakedbhost:3307" "" "fakedb" "fakeuser" "fakepass"
        else
            echo -n "8.3.99"
        fi
        exit 0
        ;;
    -m)
        printf '%s\n' bcmath ctype curl dom gd iconv intl mbstring openssl pdo_mysql simplexml soap xsl zip sockets redis apcu "Zend OPcache"
        exit 0
        ;;
    -v) echo "PHP 8.3.99 (cli) (fake)"; exit 0 ;;
esac

script="${1:-}"
shift || true
case "$script" in
    *composer*)
        wd=""
        for a in "$@"; do [[ "$a" == --working-dir=* ]] && wd="${a#--working-dir=}"; done
        if [[ "${1:-}" == "dump-autoload" && -n "$wd" ]]; then
            mkdir -p "$wd/vendor/composer"
            echo "<?php // classmap dumped in $wd" > "$wd/vendor/composer/autoload_classmap.php"
            echo "<?php // autoload dumped in $wd" > "$wd/vendor/autoload.php"
        fi
        echo "Composer version 2.7.0-fake"
        exit 0
        ;;
esac

ROOT="$(cd "$(dirname "$script")/.." && pwd)"
cmd="${1:-}"
shift || true
case "$cmd" in
    deploy:mode:show)
        echo "Current application mode: ${FAKE_MODE:-production}. (Note: Environment variables may override this value.)"
        ;;
    setup:db:status)
        [[ "${FAKE_DB_STATUS:-0}" == "0" ]] && echo "All modules are up to date."
        exit "${FAKE_DB_STATUS:-0}"
        ;;
    app:config:status)
        [[ "${FAKE_CONFIG_STATUS:-0}" == "0" ]] && echo "Config files are up to date."
        exit "${FAKE_CONFIG_STATUS:-0}"
        ;;
    setup:di:compile)
        if [[ -n "${FAKE_FAIL_DI:-}" ]]; then
            echo "Compilation failed with errors"
            exit 1
        fi
        mkdir -p "$ROOT/generated/code/Fake" "$ROOT/generated/staticcache"
        echo "<?php // compiled in $ROOT" > "$ROOT/generated/code/Fake/Interceptor.php"
        echo "<?php // plugin list" > "$ROOT/generated/staticcache/global_primary_compiled_plugins.php"
        if [[ -z "${FAKE_NO_METADATA:-}" ]]; then
            mkdir -p "$ROOT/generated/metadata"
            echo "<?php return [];" > "$ROOT/generated/metadata/global.php"
        fi
        echo "Generated code and dependency injection configuration successfully."
        ;;
    setup:static-content:deploy)
        area=""; theme=""; locale=""
        for a in "$@"; do
            case "$a" in
                --area=*)  area="${a#--area=}" ;;
                --theme=*) theme="${a#--theme=}" ;;
                --*) ;;
                *) locale="$a" ;;
            esac
        done
        if [[ -n "${FAKE_FAIL_SCD:-}" && "$area|$theme|$locale" == "$FAKE_FAIL_SCD" ]]; then
            echo "Errors during compilation: 1"
            exit 1
        fi
        [[ -n "${FAKE_SCD_SLEEP:-}" ]] && sleep "$FAKE_SCD_SLEEP"
        mkdir -p "$ROOT/pub/static/$area/$theme/$locale/css" "$ROOT/var/view_preprocessed/$area"
        echo "/* $theme $locale */" > "$ROOT/pub/static/$area/$theme/$locale/css/styles.css"
        echo "$(date +%s)" > "$ROOT/pub/static/deployed_version.txt"
        echo "Successful: 1 files; errors: 0"
        ;;
    setup:upgrade)
        if [[ -n "${FAKE_FAIL_UPGRADE:-}" ]]; then
            echo "Upgrade failed"
            exit 1
        fi
        echo "Upgrade ok"
        ;;
    maintenance:status)
        echo "Status: maintenance mode is not active"
        ;;
    *)
        echo "ok: $cmd"
        ;;
esac
exit 0
STUB

cat > "$STUBBIN/curl" <<'STUB'
#!/bin/bash
[[ -n "${FAKE_LOG:-}" ]] && echo "CURL $*" >> "$FAKE_LOG"
echo -n "${FAKE_HTTP_CODE:-200}"
exit 0
STUB

cat > "$STUBBIN/mysqldump" <<'STUB'
#!/bin/bash
[[ -n "${FAKE_LOG:-}" ]] && echo "MYSQLDUMP $*" >> "$FAKE_LOG"
echo "-- fake dump data"
exit 0
STUB

cat > "$STUBBIN/ssh" <<'STUB'
#!/bin/bash
[[ -n "${FAKE_LOG:-}" ]] && echo "SSH $*" >> "$FAKE_LOG"
exit 0
STUB

cat > "$STUBBIN/rsync" <<'STUB'
#!/bin/bash
[[ -n "${FAKE_LOG:-}" ]] && echo "RSYNC $*" >> "$FAKE_LOG"
exit 0
STUB

chmod +x "$FAKEPHP" "$STUBBIN/curl" "$STUBBIN/mysqldump" "$STUBBIN/ssh" "$STUBBIN/rsync"
echo "fake" > "$FAKECOMPOSER"

# ── Assertion helpers ──────────────────────────────────────────────

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_grep()     { if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 [pattern not found: $2]"; fi; }
assert_not_grep() { if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3 [unexpected pattern: $2]"; else ok "$3"; fi; }
assert_exit()     { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 [got $1, expected $2]"; fi; }
assert_exists()   { if [[ -e "$1" ]]; then ok "$2"; else bad "$2 [missing: $1]"; fi; }
assert_missing()  { if [[ -e "$1" ]]; then bad "$2 [still exists: $1]"; else ok "$2"; fi; }

line_of()     { grep -n -- "$1" "$FAKE_LOG_FILE" 2>/dev/null | head -1 | cut -d: -f1; }
out_line_of() { grep -n -- "$1" "$OUT" 2>/dev/null | head -1 | cut -d: -f1; }

assert_order() {  # $1 first-pattern, $2 second-pattern, $3 name (in fake.log)
    local a b
    a="$(line_of "$1")"; b="$(line_of "$2")"
    if [[ -n "$a" && -n "$b" ]] && (( a < b )); then ok "$3"; else bad "$3 [line(${1})=$a line(${2})=$b]"; fi
}
assert_out_order() {  # same, in out.txt
    local a b
    a="$(out_line_of "$1")"; b="$(out_line_of "$2")"
    if [[ -n "$a" && -n "$b" ]] && (( a < b )); then ok "$3"; else bad "$3 [line(${1})=$a line(${2})=$b]"; fi
}
count_in_log() { local n; n="$(grep -c -- "$1" "$FAKE_LOG_FILE" 2>/dev/null)"; echo "${n:-0}"; }

# ── Scenario plumbing ──────────────────────────────────────────────

# Same fingerprint pipeline as deploy.sh, over the sandbox
sandbox_fingerprint() {
    {
        ( cd "$SANDBOX" && find app/code vendor -type f \
            \( -name db_schema.xml -o -name db_schema_whitelist.json -o -name module.xml -o -path '*/Setup/*.php' \) \
            -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null )
        [[ -f "$SANDBOX/app/etc/config.php" ]] && ( cd "$SANDBOX" && cksum app/etc/config.php )
    } | cksum | awk '{print $1}'
}

seed_fingerprint() {
    mkdir -p "$SANDBOX/var/deploy"
    sandbox_fingerprint > "$SANDBOX/var/deploy/db-fingerprint"
}

setup_sandbox() {
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/app/etc" "$SANDBOX/app/code/Vendor/Module/etc" "$SANDBOX/bin" "$SANDBOX/vendor/magento/x" \
        "$SANDBOX/lib" "$SANDBOX/setup" "$SANDBOX/vendor/composer" \
        "$SANDBOX/generated/code/Old" "$SANDBOX/generated/metadata" \
        "$SANDBOX/var/view_preprocessed" "$SANDBOX/var/log" \
        "$SANDBOX/pub/static/frontend/x" "$SANDBOX/pub/static/adminhtml/x" "$SANDBOX/pub/static/_cache/merged" \
        "$SANDBOX/pub/media/catalog"
    echo "<?php return [];" > "$SANDBOX/app/etc/env.php"
    echo "<?php // old live classmap" > "$SANDBOX/vendor/composer/autoload_classmap.php"
    echo "<?php // old live autoload" > "$SANDBOX/vendor/autoload.php"
    echo "<?php return ['modules' => []];" > "$SANDBOX/app/etc/config.php"
    echo "<schema/>" > "$SANDBOX/app/code/Vendor/Module/etc/db_schema.xml"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/magento"
    chmod +x "$SANDBOX/bin/magento"
    echo '{}' > "$SANDBOX/composer.json"
    echo '{}' > "$SANDBOX/composer.lock"
    echo "version1" > "$SANDBOX/pub/static/deployed_version.txt"
    echo ".htaccess" > "$SANDBOX/pub/static/.htaccess"
    echo "deny" > "$SANDBOX/generated/.htaccess"
    touch "$SANDBOX/generated/code/Old/f.php" "$SANDBOX/generated/metadata/old.php" \
        "$SANDBOX/pub/static/frontend/x/f.css" "$SANDBOX/pub/static/_cache/merged/old.css" \
        "$SANDBOX/var/view_preprocessed/old.less" "$SANDBOX/pub/media/catalog/img.jpg" \
        "$SANDBOX/vendor/magento/x/f.php"
    seed_fingerprint
    : > "$FAKE_LOG_FILE"
    unset FAKE_MODE FAKE_DB_STATUS FAKE_CONFIG_STATUS FAKE_FAIL_DI FAKE_FAIL_SCD FAKE_FAIL_UPGRADE FAKE_NO_METADATA \
        FAKE_HTTP_CODE FAKE_SCD_SLEEP MAINTENANCE MAINTENANCE_ALLOWED_IPS DB_UPGRADE PRE_DEPLOY_CMD \
        POST_DEPLOY_CMD OPCACHE_RESET_CMD HEALTHCHECK_URL HEALTHCHECK_RETRIES HEALTHCHECK_TIMEOUT \
        DB_BACKUP DB_BACKUP_CMD SCD_EXTRA_ARGS KEEP_PREVIOUS 2>/dev/null
}

run_deploy() {
    env DEPLOY_CONFIG=/dev/null \
        PATH="$STUBBIN:$PATH" \
        PHP_BIN="$FAKEPHP" \
        COMPOSER_BIN="$FAKECOMPOSER" \
        FAKE_LOG="$FAKE_LOG_FILE" \
        FRONTEND_THEMES="Vendor/alpha, Vendor/beta" \
        FRONTEND_LANGUAGES="en_GB de_DE" \
        BACKEND_LANGUAGES="en_US en_GB" \
        PARALLEL_JOBS=2 \
        TMPDIR="$TMPDIR" \
        "$BASH_BIN" "$DEPLOY" --dir "$SANDBOX" --no-interaction "$@" > "$OUT" 2>&1
    RC=$?
}

BUILD="$SANDBOX/var/deploy/build"
PREVIOUS="$SANDBOX/var/deploy/previous"

# ── Scenarios ──────────────────────────────────────────────────────

echo "=== T0: syntax check ==="
if "$BASH_BIN" -n "$DEPLOY"; then ok "bash syntax check ($("$BASH_BIN" --version | head -1))"; else bad "bash syntax check"; fi

echo "=== T1: --help ==="
"$BASH_BIN" "$DEPLOY" --help > "$OUT" 2>&1
assert_exit $? 0 "help exits 0"
assert_grep "$OUT" "USAGE:" "help shows usage"
assert_grep "$OUT" "MAINTENANCE" "help documents maintenance modes"
assert_grep "$OUT" "DATABASE (DB_UPGRADE)" "help documents db upgrade policy"
assert_grep "$OUT" "--artifacts DIR" "help documents pipeline mode"

echo "=== T2: unknown option ==="
"$BASH_BIN" "$DEPLOY" --frobnicate > "$OUT" 2>&1
assert_exit $? 1 "unknown option exits 1"
assert_grep "$OUT" "Unknown option" "unknown option message"

echo "=== T3: missing option value must not hang ==="
perl -e '$SIG{ALRM} = sub { exit 99 }; alarm 10; my $rc = system(@ARGV); exit(($rc >> 8) & 0xff)' \
    "$BASH_BIN" "$DEPLOY" --config > "$OUT" 2>&1
rc=$?
if [[ $rc -ne 0 && $rc -ne 99 ]]; then ok "missing value errors out (exit $rc, no hang)"; else bad "missing value [exit $rc]"; fi
assert_grep "$OUT" "requires a value" "missing value message"

echo "=== T4: dry run is side-effect free ==="
setup_sandbox
run_deploy --dry-run
assert_exit $RC 0 "dry run exits 0"
assert_grep "$OUT" "dry run" "dry run announces itself"
assert_grep "$OUT" "DEPLOYMENT COMPLETE" "dry run completes"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "dry run leaves static files alone"
assert_exists "$SANDBOX/generated/code/Old/f.php" "dry run leaves generated code alone"
assert_missing "$BUILD" "dry run creates no build clone"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "dry run never enables maintenance"
assert_not_grep "$FAKE_LOG_FILE" "cache:flush" "dry run never flushes caches"
assert_not_grep "$FAKE_LOG_FILE" "static-content:deploy" "dry run never deploys static content"
assert_missing "$SANDBOX/var/.deploy.lock" "dry run takes no lock"

echo "=== T5: full zero-downtime deploy (nothing pending) ==="
setup_sandbox
run_deploy
assert_exit $RC 0 "full deploy exits 0"
assert_grep "$OUT" "DEPLOYMENT COMPLETE" "full deploy completes"
assert_grep "$OUT" "downtime 0s" "reports zero downtime"
assert_grep "$OUT" "no maintenance window needed" "announces zero-downtime release"
assert_grep "$FAKE_LOG_FILE" "memory_limit=-1" "PHP memory limit applied"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "maintenance never enabled"
assert_not_grep "$FAKE_LOG_FILE" "setup:upgrade" "no setup:upgrade when db is current"
assert_not_grep "$FAKE_LOG_FILE" "app:config:import" "no config import when config is current"
assert_grep "$FAKE_LOG_FILE" "var/deploy/build/bin/magento setup:di:compile" "di:compile runs in the build clone"
assert_grep "$FAKE_LOG_FILE" "var/deploy/build/bin/magento setup:static-content:deploy" "static deploy runs in the build clone"
assert_not_grep "$FAKE_LOG_FILE" "sandbox/bin/magento setup:di:compile" "di:compile never runs in the live tree"
assert_order "install --no-dev" "setup:db:status" "composer before db check"
assert_order "setup:db:status" "setup:di:compile" "db check before build"
assert_order "setup:di:compile" "dump-autoload" "autoloader dumped AFTER compile"
assert_order "dump-autoload" "static-content:deploy" "autoloader before static deploy"
assert_grep "$FAKE_LOG_FILE" "dump-autoload --optimize --apcu --no-plugins --no-interaction --working-dir=.*var/deploy/build" "optimized classmap dumped in the build clone"
dump_calls="$(count_in_log 'dump-autoload')"
assert_exit "$dump_calls" 1 "no optimized dump on the live tree"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "dumped in .*var/deploy/build" "new classmap live"
assert_grep "$SANDBOX/vendor/autoload.php" "dumped in .*var/deploy/build" "new vendor/autoload.php live"
assert_order "static-content:deploy" "cache:flush" "static deploy before cache flush"
scd_calls="$(count_in_log 'setup:static-content:deploy')"
assert_exit "$scd_calls" 6 "one static-content process per theme/locale (2 themes x 2 langs + backend x 2)"
assert_grep "$FAKE_LOG_FILE" "--area=frontend --theme=Vendor/beta --no-parent --force --max-execution-time=3600 de_DE" "frontend job arguments"
assert_grep "$FAKE_LOG_FILE" "--area=adminhtml --theme=Magento/backend --no-parent --force --max-execution-time=3600 --no-js-bundle en_US" "backend job arguments"
assert_not_grep "$FAKE_LOG_FILE" " -j" "magento's own --jobs is not used"
assert_exists "$SANDBOX/pub/static/frontend/Vendor/alpha/en_GB/css/styles.css" "new frontend static content live"
assert_exists "$SANDBOX/pub/static/adminhtml/Magento/backend/en_GB/css/styles.css" "new backend static content live"
assert_missing "$SANDBOX/pub/static/frontend/x/f.css" "old frontend static content replaced"
assert_missing "$SANDBOX/pub/static/_cache/merged/old.css" "stale merged css cache removed"
assert_exists "$SANDBOX/pub/static/.htaccess" "pub/static/.htaccess preserved"
assert_exists "$SANDBOX/generated/code/Fake/Interceptor.php" "new generated code live"
assert_missing "$SANDBOX/generated/code/Old/f.php" "old generated code replaced"
assert_exists "$SANDBOX/generated/metadata/global.php" "new metadata live"
assert_exists "$SANDBOX/generated/staticcache/global_primary_compiled_plugins.php" "extra compiler output (staticcache) live"
assert_exists "$SANDBOX/generated/.htaccess" "generated/.htaccess preserved"
assert_exists "$SANDBOX/vendor/magento/x/f.php" "vendor packages untouched"
assert_missing "$SANDBOX/var/view_preprocessed/old.less" "old view_preprocessed replaced"
assert_exists "$SANDBOX/pub/media/catalog/img.jpg" "media untouched"
assert_missing "$PREVIOUS" "previous artifacts removed after verification"
assert_missing "$BUILD" "build clone removed after success"
if command -v flock >/dev/null 2>&1; then
    if flock -n "$SANDBOX/var/.deploy.lock" true 2>/dev/null; then ok "lock released after success"; else bad "lock released after success [still held]"; fi
else
    assert_missing "$SANDBOX/var/.deploy.lock" "lock released after success"
fi
assert_grep "$OUT" "Already in production mode\|Application mode: production" "production mode check"
assert_grep "$OUT" "OPCACHE_RESET_CMD not set" "opcache hint shown when unset"
if ls "$SANDBOX"/var/log/deploy_report_*.txt >/dev/null 2>&1; then ok "report generated"; else bad "report generated"; fi
report="$(ls "$SANDBOX"/var/log/deploy_report_*.txt | head -1)"
assert_grep "$report" "Downtime:       0s" "report shows downtime"
logf="$(ls "$SANDBOX"/var/log/deploy_*.log | head -1)"
assert_grep "$logf" "static content: frontend|Vendor/alpha|en_GB" "per-job static output merged into main log"

echo "=== T6: first run without fingerprint baseline runs setup:upgrade once ==="
setup_sandbox
rm -f "$SANDBOX/var/deploy/db-fingerprint"
run_deploy
assert_exit $RC 0 "first run exits 0"
assert_grep "$OUT" "no baseline yet" "explains missing baseline"
assert_grep "$FAKE_LOG_FILE" "setup:upgrade --keep-generated" "setup:upgrade runs"
assert_exists "$SANDBOX/var/deploy/db-fingerprint" "fingerprint baseline written"
assert_order "static-content:deploy" "maintenance:enable" "build finished BEFORE maintenance starts"
assert_order "maintenance:enable" "setup:upgrade" "upgrade inside maintenance window"
assert_order "setup:upgrade" "cache:flush" "cache flush after upgrade"
assert_order "cache:flush" "maintenance:disable" "site reopened after cache flush"
assert_grep "$OUT" "maintenance window: setup:upgrade" "release announces the window reason"

echo "=== T7: setup:db:status=2 triggers setup:upgrade in a short window ==="
setup_sandbox
export FAKE_DB_STATUS=2
run_deploy
assert_exit $RC 0 "db upgrade deploy exits 0"
assert_grep "$OUT" "setup:db:status reports pending changes" "reason shown"
assert_grep "$FAKE_LOG_FILE" "setup:upgrade --keep-generated" "setup:upgrade runs"
assert_order "setup:di:compile" "maintenance:enable" "compile before maintenance"
assert_order "maintenance:enable" "setup:upgrade" "upgrade inside maintenance window"
assert_not_grep "$FAKE_LOG_FILE" "app:config:import" "no separate config import (covered by upgrade)"
assert_not_grep "$FAKE_LOG_FILE" "MYSQLDUMP " "no db backup when not enabled"
unset FAKE_DB_STATUS

echo "=== T8: changed db_schema.xml triggers setup:upgrade ==="
setup_sandbox
echo "<schema changed/>" > "$SANDBOX/app/code/Vendor/Module/etc/db_schema.xml"
run_deploy
assert_exit $RC 0 "fingerprint deploy exits 0"
assert_grep "$OUT" "fingerprint changed" "fingerprint change detected"
assert_grep "$FAKE_LOG_FILE" "setup:upgrade" "setup:upgrade runs on schema change"
fp_now="$(sandbox_fingerprint)"
assert_exit "$(cat "$SANDBOX/var/deploy/db-fingerprint")" "$fp_now" "fingerprint updated after upgrade"
: > "$FAKE_LOG_FILE"
run_deploy
assert_not_grep "$FAKE_LOG_FILE" "setup:upgrade" "second run skips setup:upgrade"

echo "=== T9: DB_UPGRADE=never / always ==="
setup_sandbox
export FAKE_DB_STATUS=2 DB_UPGRADE=never
run_deploy
assert_exit $RC 0 "never deploy exits 0"
assert_not_grep "$FAKE_LOG_FILE" "setup:upgrade" "DB_UPGRADE=never skips upgrade"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "no maintenance without upgrade"
assert_grep "$OUT" "DB_UPGRADE=never" "warns about skipped upgrade"
unset FAKE_DB_STATUS
setup_sandbox
run_deploy --db-upgrade always
assert_grep "$FAKE_LOG_FILE" "setup:upgrade" "DB_UPGRADE=always forces upgrade"
unset DB_UPGRADE

echo "=== T10: pending config import runs live before the build ==="
setup_sandbox
export FAKE_CONFIG_STATUS=2
run_deploy
assert_exit $RC 0 "config import deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "app:config:import" "app:config:import runs"
assert_order "app:config:import" "setup:di:compile" "config import before build"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "config import needs no maintenance"
assert_not_grep "$FAKE_LOG_FILE" "setup:upgrade" "no setup:upgrade when only config pending"
unset FAKE_CONFIG_STATUS

echo "=== T11: quick deploy keeps artifacts and builds nothing ==="
setup_sandbox
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "quick deploy exits 0"
assert_not_grep "$FAKE_LOG_FILE" "setup:di:compile" "no compile"
assert_not_grep "$FAKE_LOG_FILE" "static-content:deploy" "no static deploy"
assert_not_grep "$FAKE_LOG_FILE" "dump-autoload" "no autoloader dump without compile"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "old live classmap" "live classmap kept"
assert_missing "$BUILD" "no build clone created"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "quick deploy preserves static files"
assert_exists "$SANDBOX/generated/code/Old/f.php" "quick deploy preserves generated code"
assert_grep "$FAKE_LOG_FILE" "cache:flush" "quick deploy still flushes caches"
assert_grep "$OUT" "nothing was built" "swap reports nothing to do"

echo "=== T12: --skip-di-compile with static deploy reuses live generated code ==="
setup_sandbox
run_deploy --skip-di-compile
assert_exit $RC 0 "skip-di deploy exits 0"
assert_exists "$SANDBOX/generated/code/Old/f.php" "generated code kept"
assert_exists "$SANDBOX/pub/static/frontend/Vendor/alpha/en_GB/css/styles.css" "static content replaced"

echo "=== T13: DI failure leaves the live site untouched ==="
setup_sandbox
export FAKE_FAIL_DI=1
run_deploy
assert_exit $RC 1 "failed deploy exits 1"
di_calls="$(count_in_log 'setup:di:compile')"
assert_exit "$di_calls" 2 "di:compile retried exactly twice"
assert_grep "$OUT" "DEPLOYMENT FAILED" "failure summary shown"
assert_grep "$OUT" "were not touched (composer install already ran in place)" "explains what was and was not touched"
assert_grep "$OUT" "Failed step" "failure names the step"
assert_grep "$OUT" "Compilation failed with errors" "failure shows command output tail"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "no maintenance mode on build failure"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "live static content intact"
assert_exists "$SANDBOX/generated/code/Old/f.php" "live generated code intact"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "old live classmap" "live classmap intact"
assert_exists "$BUILD" "build clone kept for inspection"
if ls "$SANDBOX"/var/log/deploy_report_*.txt >/dev/null 2>&1; then ok "failure report generated"; else bad "failure report generated"; fi
unset FAKE_FAIL_DI
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "follow-up run succeeds after failure"
assert_not_grep "$OUT" "already running" "no stale lock after failure"

echo "=== T14: one failing static-content job fails the build, live untouched ==="
setup_sandbox
export FAKE_FAIL_SCD="frontend|Vendor/beta|de_DE"
run_deploy
assert_exit $RC 1 "scd failure exits 1"
assert_grep "$OUT" "frontend Vendor/beta de_DE" "failed job named"
assert_grep "$OUT" "5/6 jobs succeeded" "job counts reported"
assert_grep "$OUT" "live site untouched" "live site untouched message"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "live static content intact"
assert_missing "$SANDBOX/pub/static/frontend/Vendor/alpha" "nothing swapped in"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "old live classmap" "live classmap not written through the clone (dump ran before the failure)"
assert_grep "$BUILD/vendor/composer/autoload_classmap.php" "dumped in .*var/deploy/build" "build clone has its own classmap"
assert_grep "$SANDBOX/vendor/autoload.php" "old live autoload" "live vendor/autoload.php untouched"
unset FAKE_FAIL_SCD

echo "=== T15: static-content jobs really run in parallel ==="
setup_sandbox
export FAKE_SCD_SLEEP=2
t0=$(date +%s)
run_deploy -j 6
t1=$(date +%s)
assert_exit $RC 0 "parallel deploy exits 0"
# sequential execution would need at least 12s for six 2-second jobs
if (( t1 - t0 < 10 )); then ok "six 2-second jobs finished in $(( t1 - t0 ))s (parallel)"; else bad "jobs did not run in parallel ($(( t1 - t0 ))s)"; fi
assert_grep "$OUT" "6 jobs on" "reports job count and workers"
unset FAKE_SCD_SLEEP

if command -v flock >/dev/null 2>&1; then
    echo "=== T16: lock contention (flock) ==="
    setup_sandbox
    mkdir -p "$SANDBOX/var"
    touch "$SANDBOX/var/.deploy.lock"
    flock -x "$SANDBOX/var/.deploy.lock" -c "sleep 15" &
    HOLDER=$!
    sleep 1
    run_deploy --skip-static --skip-di-compile
    assert_exit $RC 1 "concurrent deploy refused"
    assert_grep "$OUT" "already running" "reports running deployment"
    pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    HOLDER=""
    echo "=== T17: leftover lock file (flock auto-recovers) ==="
    setup_sandbox
    echo "999999" > "$SANDBOX/var/.deploy.lock"
    run_deploy --skip-static --skip-di-compile
    assert_exit $RC 0 "leftover unheld lock file ignored"
else
    echo "=== T16: lock contention (pidfile) ==="
    setup_sandbox
    sleep 15 &
    HOLDER=$!
    echo "$HOLDER" > "$SANDBOX/var/.deploy.lock"
    run_deploy --skip-static --skip-di-compile
    assert_exit $RC 1 "concurrent deploy refused"
    assert_grep "$OUT" "already running" "reports running deployment"
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    HOLDER=""
    echo "=== T17: stale lock recovery (pidfile) ==="
    setup_sandbox
    ( : ) &
    DEADPID=$!
    wait "$DEADPID" 2>/dev/null
    echo "$DEADPID" > "$SANDBOX/var/.deploy.lock"
    run_deploy --skip-static --skip-di-compile
    assert_exit $RC 0 "stale lock recovered"
    assert_grep "$OUT" "stale" "reports stale lock removal"
fi

echo "=== T18: .deploy.env loading and priority ==="
setup_sandbox
cat > "$SANDBOX/.deploy.env" <<CONF
# test config
PHP_BIN=/bogus/php-from-config    # env var must override this
PARALLEL_JOBS=3
FRONTEND_THEMES="Cfg/theme"
MAINTENANCE='never'
CONF
env PHP_BIN="$FAKEPHP" COMPOSER_BIN="$FAKECOMPOSER" FAKE_LOG="$FAKE_LOG_FILE" TMPDIR="$TMPDIR" \
    "$BASH_BIN" "$DEPLOY" --dir "$SANDBOX" --no-interaction --dry-run > "$OUT" 2>&1
assert_exit $? 0 "config-file run exits 0"
assert_grep "$OUT" "Config file" "config file detected"
assert_grep "$OUT" "PHP 8.3.99" "env PHP_BIN overrides config"
assert_grep "$OUT" "3 static-content processes" "PARALLEL_JOBS read from config"
assert_grep "$OUT" "Cfg/theme" "quoted theme value parsed"
assert_grep "$OUT" "Maintenance     never" "single-quoted value parsed"

echo "=== T19: MAINTENANCE=always / never ==="
setup_sandbox
export MAINTENANCE=always
run_deploy
assert_exit $RC 0 "maintenance=always deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "maintenance:enable" "window opened although no upgrade"
assert_order "static-content:deploy" "maintenance:enable" "build still happens before the window"
assert_order "maintenance:enable" "cache:flush" "cache flush inside window"
assert_order "cache:flush" "maintenance:disable" "window closed after flush"
setup_sandbox
export MAINTENANCE=never FAKE_DB_STATUS=2
run_deploy
assert_exit $RC 0 "maintenance=never deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "setup:upgrade" "upgrade still runs"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:enable" "maintenance never enabled"
assert_grep "$OUT" "LIVE site" "warns about live upgrade"
unset MAINTENANCE FAKE_DB_STATUS

echo "=== T20: maintenance IP whitelist ==="
setup_sandbox
export MAINTENANCE_ALLOWED_IPS="1.2.3.4, 5.6.7.8" FAKE_DB_STATUS=2
run_deploy
assert_exit $RC 0 "whitelist deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "--ip=1.2.3.4" "first IP passed"
assert_grep "$FAKE_LOG_FILE" "--ip=5.6.7.8" "second IP passed"
unset MAINTENANCE_ALLOWED_IPS FAKE_DB_STATUS

echo "=== T21: pre/post hooks run in order with correct cwd ==="
setup_sandbox
SANDBOX_REAL="$(cd "$SANDBOX" && pwd)"
export PRE_DEPLOY_CMD='echo "PRE-HOOK cwd=$(pwd)"'
export POST_DEPLOY_CMD='echo POST-HOOK-RAN'
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "hooks deploy exits 0"
assert_grep "$OUT" "PRE-HOOK cwd=$SANDBOX_REAL" "pre hook ran in MAGENTO_DIR"
assert_grep "$OUT" "POST-HOOK-RAN" "post hook ran"
assert_out_order "PRE-HOOK cwd=" "composer install" "pre hook before composer"
assert_out_order "Post-deployment checks passed" "POST-HOOK-RAN" "post hook after checks"
unset PRE_DEPLOY_CMD POST_DEPLOY_CMD

echo "=== T22: failing pre-deploy hook aborts before any change ==="
setup_sandbox
export PRE_DEPLOY_CMD='exit 3'
run_deploy --skip-static --skip-di-compile
assert_exit $RC 1 "failing pre hook aborts"
assert_grep "$OUT" "Pre-deploy hook failed" "pre hook failure reported"
assert_not_grep "$FAKE_LOG_FILE" "install --no-dev" "composer never ran after failed pre hook"
unset PRE_DEPLOY_CMD

echo "=== T23: failing post-deploy hook only warns ==="
setup_sandbox
export POST_DEPLOY_CMD='false'
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "failing post hook does not fail deploy"
assert_grep "$OUT" "Post-deploy hook failed" "post hook failure warned"
unset POST_DEPLOY_CMD

echo "=== T24: OPcache reset after the swap, before the site reopens ==="
setup_sandbox
export OPCACHE_RESET_CMD='echo OPCACHE-RESET-DONE' FAKE_DB_STATUS=2
run_deploy
assert_exit $RC 0 "opcache deploy exits 0"
assert_grep "$OUT" "OPCACHE-RESET-DONE" "opcache reset ran"
assert_out_order "Swapped" "^    OPCACHE-RESET-DONE" "opcache reset after artifact swap"
assert_out_order "^    OPCACHE-RESET-DONE" "maintenance:disable" "opcache reset before site reopens"
unset FAKE_DB_STATUS
setup_sandbox
export OPCACHE_RESET_CMD='false'
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "failed opcache reset does not fail deploy"
assert_grep "$OUT" "stale code" "opcache failure warns about stale code"
unset OPCACHE_RESET_CMD

echo "=== T25: health check ==="
setup_sandbox
export HEALTHCHECK_URL='https://shop.example.test/'
run_deploy
assert_exit $RC 0 "healthy deploy exits 0"
assert_grep "$OUT" "Health check: https://shop.example.test/" "health check passed"
assert_order "cache:flush" "CURL " "health check after release"
setup_sandbox
export HEALTHCHECK_URL='https://shop.example.test/' FAKE_HTTP_CODE=503 HEALTHCHECK_RETRIES=2
run_deploy --skip-static --skip-di-compile
assert_exit $RC 1 "unhealthy deploy fails"
assert_grep "$OUT" "Health check failed" "health check failure reported"
curl_calls="$(count_in_log 'CURL ')"
assert_exit "$curl_calls" 2 "health check retried per HEALTHCHECK_RETRIES"
unset HEALTHCHECK_URL FAKE_HTTP_CODE HEALTHCHECK_RETRIES

echo "=== T26: built-in DB backup before the maintenance window ==="
setup_sandbox
export FAKE_DB_STATUS=2 DB_BACKUP=true
run_deploy
assert_exit $RC 0 "backup deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "MYSQLDUMP " "mysqldump invoked"
assert_grep "$FAKE_LOG_FILE" "-h fakedbhost" "db host parsed from env.php"
assert_grep "$FAKE_LOG_FILE" "-P 3307" "host:port split applied"
assert_order "MYSQLDUMP " "maintenance:enable" "backup does not add downtime"
assert_order "MYSQLDUMP " "setup:upgrade" "backup before setup:upgrade"
bfile="$(ls "$SANDBOX"/var/backups/deploy_db_*.sql.gz 2>/dev/null | head -1)"
if [[ -n "$bfile" ]] && gzip -t "$bfile" 2>/dev/null; then ok "backup file is valid gzip"; else bad "backup file is valid gzip"; fi
unset FAKE_DB_STATUS DB_BACKUP
setup_sandbox
export FAKE_DB_STATUS=2 DB_BACKUP_CMD='echo CUSTOM-BACKUP-RAN'
run_deploy
assert_exit $RC 0 "custom backup deploy exits 0"
assert_grep "$OUT" "CUSTOM-BACKUP-RAN" "custom backup command ran"
assert_not_grep "$FAKE_LOG_FILE" "MYSQLDUMP " "builtin mysqldump not used"
unset FAKE_DB_STATUS DB_BACKUP_CMD

echo "=== T27: setup:upgrade failure leaves maintenance on and keeps previous artifacts ==="
setup_sandbox
export FAKE_DB_STATUS=2 FAKE_FAIL_UPGRADE=1
run_deploy
assert_exit $RC 1 "failed upgrade exits 1"
assert_grep "$OUT" "Maintenance mode is still ENABLED" "warns maintenance left on"
assert_grep "$OUT" "maintenance:disable" "prints manual disable command"
assert_grep "$OUT" "previous ones are in" "points to previous artifacts"
assert_exists "$PREVIOUS/generated/code/Old/f.php" "previous generated code kept"
assert_exists "$PREVIOUS/pub/static/frontend/x/f.css" "previous static content kept"
assert_not_grep "$FAKE_LOG_FILE" "maintenance:disable" "maintenance NOT auto-disabled on failure"
assert_missing "$SANDBOX/var/deploy/db-fingerprint.new" "no fingerprint side files"
unset FAKE_DB_STATUS FAKE_FAIL_UPGRADE

echo "=== T28: --keep-previous ==="
setup_sandbox
run_deploy --keep-previous
assert_exit $RC 0 "keep-previous deploy exits 0"
assert_exists "$PREVIOUS/pub/static/frontend/x/f.css" "previous static kept on request"

echo "=== T29: --build-only produces artifacts without releasing ==="
setup_sandbox
run_deploy --build-only
assert_exit $RC 0 "build-only exits 0"
assert_grep "$OUT" "BUILD COMPLETE" "build-only summary"
assert_exists "$BUILD/generated/code/Fake/Interceptor.php" "artifacts left in build dir"
assert_exists "$BUILD/pub/static/frontend/Vendor/alpha/en_GB/css/styles.css" "static artifacts left in build dir"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "live static untouched"
assert_not_grep "$FAKE_LOG_FILE" "setup:db:status" "no db check in build-only"
assert_not_grep "$FAKE_LOG_FILE" "cache:flush" "no release in build-only"

echo "=== T30: --artifacts releases pre-built artifacts ==="
ARTIFACTS="$WORK/artifacts"
rm -rf "$ARTIFACTS"; cp -R "$BUILD" "$ARTIFACTS"
setup_sandbox
run_deploy --artifacts "$ARTIFACTS"
assert_exit $RC 0 "artifacts deploy exits 0"
assert_not_grep "$FAKE_LOG_FILE" "install --no-dev" "no composer install"
assert_not_grep "$FAKE_LOG_FILE" "setup:di:compile" "no compile"
assert_not_grep "$FAKE_LOG_FILE" "static-content:deploy" "no static deploy"
assert_exists "$SANDBOX/generated/code/Fake/Interceptor.php" "pre-built generated code live"
assert_exists "$SANDBOX/pub/static/frontend/Vendor/beta/de_DE/css/styles.css" "pre-built static content live"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "dumped in" "pre-built classmap live"
assert_exists "$SANDBOX/generated/staticcache/global_primary_compiled_plugins.php" "pre-built staticcache live"
assert_exists "$ARTIFACTS/pub/static/deployed_version.txt" "artifacts source left intact"
assert_grep "$FAKE_LOG_FILE" "cache:flush" "release still flushes caches"
setup_sandbox
run_deploy --artifacts "$WORK/does-not-exist"
assert_exit $RC 1 "missing artifacts dir is rejected"

echo "=== T30b: --push uploads artifacts over ssh and can run the remote release ==="
setup_sandbox
run_deploy --push www@shop.example.test:/var/www/html --push-run
assert_exit $RC 0 "push deploy exits 0"
assert_grep "$OUT" "BUILD COMPLETE" "push implies build-only"
assert_grep "$FAKE_LOG_FILE" "SSH www@shop.example.test mkdir -p '/var/www/html/var/deploy/incoming'" "incoming dir created on server"
assert_grep "$FAKE_LOG_FILE" "RSYNC -az --delete -e ssh .*var/deploy/build/generated/ www@shop.example.test:/var/www/html/var/deploy/incoming/generated/" "generated/ uploaded"
assert_grep "$FAKE_LOG_FILE" "RSYNC .*pub/static/ www@shop.example.test:/var/www/html/var/deploy/incoming/pub/static/" "static content uploaded"
assert_grep "$FAKE_LOG_FILE" "RSYNC .*vendor/composer/ www@shop.example.test:/var/www/html/var/deploy/incoming/vendor/composer/" "classmap uploaded"
assert_grep "$FAKE_LOG_FILE" "RSYNC .*vendor/autoload.php www@shop.example.test:/var/www/html/var/deploy/incoming/vendor/autoload.php" "vendor/autoload.php uploaded"
assert_grep "$FAKE_LOG_FILE" "SSH -t www@shop.example.test cd '/var/www/html' && ./deploy.sh --artifacts '/var/www/html/var/deploy/incoming' --no-interaction" "remote release started"
assert_not_grep "$FAKE_LOG_FILE" "cache:flush" "no local release"
setup_sandbox
run_deploy --push not-a-target
assert_exit $RC 1 "malformed push target rejected"

echo "=== T30b2: DI compiler without generated/metadata (creatuity interceptors) ==="
setup_sandbox
export FAKE_NO_METADATA=1
run_deploy
assert_exit $RC 0 "deploy without metadata exits 0"
assert_grep "$OUT" "no generated/metadata produced" "explains the missing metadata"
assert_exists "$SANDBOX/generated/staticcache/global_primary_compiled_plugins.php" "staticcache live"
assert_missing "$SANDBOX/generated/metadata" "stale live metadata retired"
assert_grep "$OUT" "\-generated/metadata" "retired entry reported"
unset FAKE_NO_METADATA

echo "=== T30c: leftover var/.regenerate is cleared before the first live bin/magento call ==="
setup_sandbox
touch "$SANDBOX/var/.regenerate" "$SANDBOX/var/.regenerate.lock"
run_deploy
assert_exit $RC 0 "regenerate deploy exits 0"
assert_missing "$SANDBOX/var/.regenerate" "flag removed"
assert_missing "$SANDBOX/var/.regenerate.lock" "flag lock removed"
assert_grep "$OUT" "Removed var/.regenerate" "flag removal reported"
assert_out_order "Removed var/.regenerate" "setup:db:status" "flag removed before setup:db:status"
setup_sandbox
touch "$SANDBOX/var/.regenerate"
run_deploy --skip-di-compile --skip-static
assert_grep "$OUT" "run without --skip-di-compile soon" "warns when generated code is kept"

# ── Git mode ───────────────────────────────────────────────────────
setup_git_sandbox() {
    setup_sandbox
    ORIGIN="$WORK/origin.git"
    rm -rf "$ORIGIN"
    git init -q --bare "$ORIGIN"
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master
    (
        cd "$SANDBOX" || exit 1
        git init -q
        git symbolic-ref HEAD refs/heads/master
        git config user.email t@example.test; git config user.name t
        # anchored patterns: an unanchored "vendor/" would also match app/code/Vendor on
        # case-insensitive filesystems (macOS)
        printf '/app/etc/env.php\n/generated/code/\n/generated/metadata/\n/pub/static/frontend/\n/pub/static/adminhtml/\n/pub/static/_cache/\n/pub/static/deployed_version.txt\n/var/\n/vendor/\n/pub/media/\n/pub/errors/local.xml\n' > .gitignore
        mkdir -p app/code/Vendor/Module pub/errors lib
        echo "<?php // version 1" > app/code/Vendor/Module/Thing.php
        echo "old lib" > lib/old.txt
        echo "<?php // index v1" > pub/index.php
        echo "<xml/>" > pub/errors/design.xml
        echo "<?php // local error config" > pub/errors/local.xml
        git add -A >/dev/null
        git commit -q -m "v1"
        echo "local note" > local-note.txt
        git remote add origin "$ORIGIN"
        git push -q origin HEAD:master
        git branch -q --set-upstream-to=origin/master 2>/dev/null || git branch -q -u origin/master
    )
    # a newer commit in origin, made from another clone
    local clone="$WORK/clone"
    rm -rf "$clone"
    git clone -q -b master "$ORIGIN" "$clone"
    (
        cd "$clone" || exit 1
        git config user.email t@example.test; git config user.name t
        echo "<?php // version 2" > app/code/Vendor/Module/Thing.php
        git rm -q -r lib
        echo "<?php // new" > pub/new.php
        echo "<schema v2/>" > app/code/Vendor/Module/etc/db_schema.xml
        git add -A >/dev/null
        git commit -q -m "v2"
        git push -q origin HEAD:master
    )
    NEW_SHA="$(git -C "$clone" rev-parse HEAD)"
    OLD_SHA="$(git -C "$SANDBOX" rev-parse HEAD)"
}

echo "=== T30d: git mode deploys a ref without touching the live checkout before the swap ==="
setup_git_sandbox
run_deploy --ref origin/master
assert_exit $RC 0 "git deploy exits 0"
assert_grep "$OUT" "Deploying ${NEW_SHA:0:10}" "announces the target commit"
assert_grep "$FAKE_LOG_FILE" "install --no-dev --no-interaction --no-progress --prefer-dist --working-dir=.*var/deploy/build" "composer install runs in the build"
assert_not_grep "$FAKE_LOG_FILE" "install --no-dev .*--working-dir=$SANDBOX\$" "composer never runs on the live tree"
assert_grep "$FAKE_LOG_FILE" "var/deploy/build/bin/magento setup:db:status" "db status checked against the new code"
assert_order "setup:di:compile" "sandbox/bin/magento cache:flush" "live bin/magento used again after the swap"
assert_grep "$SANDBOX/app/code/Vendor/Module/Thing.php" "version 2" "new code live"
assert_exists "$SANDBOX/pub/new.php" "new pub file live"
assert_missing "$SANDBOX/lib" "removed tracked directory retired"
assert_exists "$SANDBOX/app/etc/env.php" "env.php preserved"
assert_grep "$SANDBOX/pub/errors/local.xml" "local error config" "ignored file inside a swapped directory carried over"
assert_exists "$SANDBOX/local-note.txt" "untracked root file untouched"
assert_exists "$SANDBOX/vendor/magento/x/f.php" "live vendor merged into the release"
assert_exists "$SANDBOX/pub/media/catalog/img.jpg" "media untouched"
assert_exists "$SANDBOX/pub/static/frontend/Vendor/alpha/en_GB/css/styles.css" "static content released"
assert_exists "$SANDBOX/generated/code/Fake/Interceptor.php" "generated code released"
assert_grep "$SANDBOX/vendor/composer/autoload_classmap.php" "dumped in .*var/deploy/build" "classmap released"
assert_exit "$(git -C "$SANDBOX" rev-parse HEAD)" "$NEW_SHA" "git HEAD moved to the deployed commit"
dirty="$(git -C "$SANDBOX" status --porcelain -uno | wc -l | tr -d ' ')"
assert_exit "$dirty" 0 "git index matches the working tree after the release"
assert_grep "$FAKE_LOG_FILE" "setup:upgrade" "changed db_schema.xml in the new commit triggers setup:upgrade"
assert_grep "$OUT" "carried over" "reports carried over files"
assert_grep "$OUT" "git HEAD moved" "reports git reset"

echo "=== T30e: git mode failure leaves code, HEAD and artifacts untouched ==="
setup_git_sandbox
export FAKE_FAIL_DI=1
run_deploy --ref origin/master
assert_exit $RC 1 "git deploy failure exits 1"
assert_grep "$SANDBOX/app/code/Vendor/Module/Thing.php" "version 1" "live code untouched"
assert_exists "$SANDBOX/lib/old.txt" "nothing retired"
assert_exit "$(git -C "$SANDBOX" rev-parse HEAD)" "$OLD_SHA" "git HEAD unchanged"
assert_exists "$SANDBOX/pub/static/frontend/x/f.css" "live static untouched"
assert_grep "$OUT" "The live site was not touched" "reports the live site untouched (composer ran in the build only)"
unset FAKE_FAIL_DI

echo "=== T30f: git mode dry run and validation ==="
setup_git_sandbox
run_deploy --ref origin/master --dry-run
assert_exit $RC 0 "git dry run exits 0"
assert_grep "$OUT" "Would export origin/master" "dry run describes the export"
assert_grep "$OUT" "Would swap: app" "dry run lists the code swap"
assert_grep "$OUT" "retire: lib" "dry run lists retired entries"
assert_grep "$SANDBOX/app/code/Vendor/Module/Thing.php" "version 1" "dry run changes nothing"
assert_exit "$(git -C "$SANDBOX" rev-parse HEAD)" "$OLD_SHA" "dry run leaves HEAD"
run_deploy --ref does-not-exist
assert_exit $RC 1 "unresolvable ref fails"
assert_grep "$OUT" "Cannot resolve git ref" "unresolvable ref message"
setup_sandbox
run_deploy --ref origin/master
assert_exit $RC 1 "git mode without a checkout is refused"
assert_grep "$OUT" "requires .* to be a git checkout" "explains the missing checkout"
setup_git_sandbox
run_deploy --git --skip-static --skip-di-compile
assert_exit $RC 0 "--git uses the upstream"
assert_exit "$(git -C "$SANDBOX" rev-parse HEAD)" "$NEW_SHA" "--git deployed the upstream commit"
assert_grep "$SANDBOX/app/code/Vendor/Module/Thing.php" "version 2" "code swapped even without artifacts"

echo "=== T31: developer mode is switched to production ==="
setup_sandbox
export FAKE_MODE=developer
run_deploy --skip-static --skip-di-compile
assert_exit $RC 0 "developer mode deploy exits 0"
assert_grep "$FAKE_LOG_FILE" "deploy:mode:set production --skip-compilation" "production mode set from developer"
unset FAKE_MODE

echo "=== T32: --ascii output ==="
setup_sandbox
run_deploy --ascii --skip-static --skip-di-compile
assert_exit $RC 0 "ascii deploy exits 0"
if grep -q '[^ -~]' "$OUT"; then bad "ascii mode prints no non-ASCII characters"; else ok "ascii mode prints no non-ASCII characters"; fi

echo
echo "================================"
echo "RESULTS: $PASS passed, $FAIL failed"
echo "================================"
exit $(( FAIL > 0 ? 1 : 0 ))

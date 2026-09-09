# Magento 2 zero-downtime deployment

`deploy.sh` is a single-file, dependency-free Bash script that deploys a Magento 2 installation **in place** (the same directory the web server serves) **without taking the shop offline**. It runs on macOS and Linux with Bash 3.2 or newer, and needs only what a Magento host already has: PHP, Composer, `xargs`, `cp`, `mv`, `find`.

Українська версія: [README.uk.md](README.uk.md)

---

## Contents

1. [What it does differently](#what-it-does-differently)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Quick start](#quick-start)
5. [How a deployment works, phase by phase](#how-a-deployment-works-phase-by-phase)
6. [Zero-downtime model and its limits](#zero-downtime-model-and-its-limits)
7. [Failure handling and recovery](#failure-handling-and-recovery)
8. [Policies: `DB_UPGRADE` and `MAINTENANCE`](#policies-db_upgrade-and-maintenance)
9. [Pipeline mode: build once, release elsewhere](#pipeline-mode-build-once-release-elsewhere)
10. [Configuration reference](#configuration-reference)
11. [Command line reference](#command-line-reference)
12. [Logs, reports and retention](#logs-reports-and-retention)
13. [Locking](#locking)
14. [Terminal output](#terminal-output)
15. [Testing](#testing)
16. [Troubleshooting](#troubleshooting)
17. [License](#license)

---

## What it does differently

A classic Magento deployment enables maintenance mode, deletes `generated/` and `pub/static/`, compiles, deploys static content and reopens the shop. With several themes and many locales that means ten to forty minutes of downtime per release.

This script keeps the shop online for the whole build:

| Concern | How it is handled |
|---|---|
| Getting the new code | With `--ref` / `--git` the script does `git fetch` (touches only `.git`) and exports the commit into the build clone. The live checkout is not modified until the swap, so there is no "new code, old generated code" window. Without a ref the code is expected to be in place already. |
| Compiling DI and static content | Done inside a **build clone** of the code tree (`var/deploy/build`) while the live `generated/` and `pub/static/` keep serving traffic. |
| Multi-core static content | One `setup:static-content:deploy` process per (theme, locale) pair, fanned out with `xargs -P` over all CPU cores. Magento's own `--jobs` option is not used. |
| Putting the new release live | Directory **renames** (`mv`), which take milliseconds: `generated/`, `pub/static/*`, the Composer classmap and, in git mode, `app/`, `lib/`, `setup/`, `bin/`, `vendor/`, `pub/*`. The replaced entries are kept until the release is verified. |
| Optimized Composer classmap | Generated **after** `setup:di:compile`, inside the clone, and swapped together with `generated/` so the classmap can never point at missing files. |
| `setup:upgrade` | Runs **only** when database changes are detected: `setup:db:status`, plus a fingerprint of `db_schema.xml`, `db_schema_whitelist.json`, `module.xml`, `Setup/` files and `app/etc/config.php`. |
| Maintenance mode | Entered **only** while `setup:upgrade` runs (policy `auto`). A release without database changes has zero downtime. |
| Everything else | Locking, pre/post hooks, OPcache reset, health check, database backup, IP whitelist, dry run, logs, reports, retention, a config wizard. |

---

## Requirements

- Magento 2.3+ (tested with 2.4.x), installed in a directory the script can write to.
- Bash 3.2+ (macOS default) or any newer Bash on Linux.
- PHP CLI with the extensions Magento needs; Composer 2 (a `composer.phar` in the Magento root is detected automatically).
- `xargs` with `-P` (GNU or BSD), `cp`, `mv`, `find`, `cksum`, `sort`, `mktemp`, `df`.
- `var/` must be on the **same filesystem** as `pub/` and `generated/`. Hardlink clones and atomic renames do not work across filesystems; the script checks this in preflight.
- Optional: `flock` (Linux; macOS falls back to a PID lock file), `curl` for the health check, `mysqldump` for the built-in backup, `rsync` and `ssh` for `--push`.
- Free disk space for one extra copy of `generated/` and `pub/static/` during the build (old and new exist side by side).

---

## Installation

Run inside the Magento root:

```bash
curl -fsSL https://raw.githubusercontent.com/hryvinskyi/magento2-deployment/main/install.sh | bash
```

Options are passed after `bash -s --`:

```bash
# install into another directory, pin a tag
curl -fsSL https://raw.githubusercontent.com/hryvinskyi/magento2-deployment/main/install.sh \
  | bash -s -- --dir /var/www/html --ref v3.0.0

# do not download .deploy.env.example
curl -fsSL .../install.sh | bash -s -- --no-config
```

The installer downloads `deploy.sh`, verifies it with `bash -n`, makes it executable, and adds `.deploy.env.example`. Re-running it updates `deploy.sh` in place and keeps the previous copy as `deploy.sh.bak` when it differs. `MAGENTO_DIR` and `DEPLOY_REF` environment variables are honoured; `DEPLOY_BASE_URL` overrides the download location (mirrors, tests).

Manual installation is just copying `deploy.sh` into the Magento root and `chmod +x deploy.sh`.

---

## Quick start

```bash
cd /var/www/html
./deploy.sh --init                    # detects themes and locales from the database, writes .deploy.env
./deploy.sh --ref origin/main --dry-run   # shows every command that would run, changes nothing
./deploy.sh --ref origin/main         # deploys that commit; the live checkout is untouched until the swap
./deploy.sh                           # code already in place (after your own git pull / rsync)
```

Two ways to get the code onto the server:

- **Git mode** (`--ref REF`, `--git`, `GIT_REF=`): recommended when the Magento root is a git checkout. The script fetches, exports the commit into the build, installs Composer packages there, builds, and swaps code and artifacts together. `git pull` on the live docroot is never needed.
- **In-place mode** (no ref): the code is already updated (by you, `PRE_DEPLOY_CMD`, rsync, CI); `composer install` runs live and only the artifacts are built and swapped.

Typical `.deploy.env` for a production host:

```ini
MAGENTO_DIR=/var/www/html
PHP_BIN=php8.3
COMPOSER_BIN=/usr/local/bin/composer
FRONTEND_THEMES=Vendor/theme,Vendor/other
FRONTEND_LANGUAGES=en_GB de_DE fr_FR
BACKEND_THEME=Magento/backend
BACKEND_LANGUAGES=en_US en_GB
PARALLEL_JOBS=12
OPCACHE_RESET_CMD=sudo systemctl reload php8.3-fpm
HEALTHCHECK_URL=https://www.example.com/
DB_BACKUP=true
GIT_REF=origin/main
```

The usual release is then just `./deploy.sh`.

---

## How a deployment works, phase by phase

```
preflight → pre-deploy hook → [source: git fetch + export] → composer → database check → build (live) → release → verify → post-deploy hook
```

### 1. Preflight

- Resolves `MAGENTO_DIR` to an absolute path and checks `app/etc/env.php`, `bin/magento`, `composer.json`. Fixes a non-executable `bin/magento`.
- Checks the PHP binary and the extensions Magento requires (`bcmath ctype curl dom gd iconv intl mbstring openssl pdo_mysql simplexml soap xsl zip sockets`); warns about missing `redis`, `apcu`, `opcache`.
- Resolves Composer to an absolute path (`COMPOSER_BIN`, `$PATH`, `composer.phar` in the Magento root) because it is executed through `$PHP_BIN` with the configured `memory_limit`.
- Validates every option; invalid values fall back to their defaults with a warning.
- Checks that `BUILD_DIR` (default `var/deploy`) is on the same filesystem as `pub/`.
- Reports CPU cores, free memory and free disk. `PARALLEL_JOBS` defaults to the core count and is capped at it; a warning is printed when the jobs would need more memory than is available (about 700 MB per process).
- Takes the deployment lock (see [Locking](#locking)).
- Warns when running as root (files would be root-owned).

Validation errors ask for confirmation to continue; with `--no-interaction` or without a terminal the deployment aborts.

### 2. Pre-deploy hook

`PRE_DEPLOY_CMD` runs in the Magento directory with its output shown. A non-zero exit aborts the deployment before anything was changed. This is the place for notifications or custom checks (and for `git pull --ff-only` if you deploy in in-place mode).

### 2b. Source (git mode only)

Active with `--ref REF`, `--git` (the current branch's upstream) or `GIT_REF`. The Magento root must be a git checkout and `git`, `tar` must be available.

1. Production mode is ensured first (`env.php` only), because the build copies `env.php`.
2. `git fetch --prune --tags GIT_REMOTE` (default remote `origin`). This touches nothing but `.git`. A dry run fetches too, otherwise it would plan against a stale ref.
3. The ref is resolved to a commit; an unresolvable ref aborts. The current `HEAD` is remembered. Locally modified tracked files in the live checkout produce a warning: they will be replaced by the release (and kept in `var/deploy/previous`).
4. The swap plan is computed from `git ls-tree`: every tracked top-level entry of the new commit except `.git*`, `var`, `generated`, `pub`, `deploy.sh` and `.deploy.env`, plus every tracked entry directly under `pub/` except `pub/media` and `pub/static`. Tracked entries that exist in the current commit but not in the new one are scheduled to be retired.
5. `git archive <commit> | tar -x` exports the tree into `var/deploy/build`. The live `vendor/` is then **merged** into the build with hardlinks (`cp -aln`; APFS clones on macOS; `BUILD_COPY_VENDOR=true` forces a real copy) without overwriting files that came from git, so `composer install` afterwards only has to install what changed.
6. Untracked and ignored files that live **inside the directories that will be swapped** (for example `app/etc/env.php`, `pub/errors/local.xml`, local module configs) are carried over into the build with `git ls-files --others`, so they survive the swap. The live `app/etc/env.php` is always copied last. Untracked entries next to swapped ones (a `pub/customwp/`, root-level scripts) are simply not part of the swap and stay as they are.
7. `vendor/composer`, `vendor/autoload.php` and `app/etc/NonComposerComponentRegistration.php` are detached so Composer cannot write through hardlinks into the live tree; `pub/media` is symlinked; with `--skip-di-compile` the live generated code is cloned in.

From here on the build directory is a complete, self-contained copy of the new release, and the live checkout has not been modified.

### 3. Composer

`composer install --no-dev --no-interaction --no-progress --prefer-dist` runs from `composer.lock` (a missing lock file aborts). In **git mode** it runs inside the build (`--working-dir=var/deploy/build`), the live `vendor/` is untouched. In **in-place mode** it runs live; the shop keeps serving because Composer replaces packages atomically per file and OPcache keeps the old bytecode until it is reset.

Composer writes a **plain** autoloader here. The optimized classmap is deliberately **not** generated at this point: `composer dump-autoload --optimize` hard-codes every file in `generated/code`, and that directory is about to be replaced. See phase 5.

`--skip-composer` skips this phase.

### 4. Database check

In git mode every `bin/magento` call of this phase uses the **build's** `bin/magento`, so the status is checked against the new code (the database and `env.php` are the live ones).

1. A leftover `var/.regenerate` flag is removed. Magento deletes `generated/` and `var/cache` on its **next bootstrap** when this flag exists (`module:enable` / `module:disable` leave it behind). On a live production site that would be a fatal-error window, and this deployment rebuilds the generated code anyway. With `--skip-di-compile` a warning explains that the code Magento wanted rebuilt is being kept.
2. `setup:db:status` — exit code 2 means module versions require an upgrade.
3. `app:config:status` — exit code 2 means `config.php` / `env.php` contain settings that are not in the database yet.
4. **Database fingerprint.** `setup:db:status` only compares `setup_version` values; modules without one (every module using declarative schema and data patches) are always reported as up to date. The script therefore computes a checksum over every `db_schema.xml`, `db_schema_whitelist.json`, `module.xml` and `Setup/**/*.php` in `app/code` and `vendor`, plus `app/etc/config.php`, using paths relative to the Magento root. The value of the last successful upgrade is stored in `var/deploy/db-fingerprint`. A different value means new schema or patches exist and `setup:upgrade` is required. Without a stored value (first run, or after `var/` was cleaned) the upgrade runs once to establish the baseline.
5. The `DB_UPGRADE` policy is applied (see [Policies](#policies-db_upgrade-and-maintenance)).
6. When a config import is pending and no upgrade will run, `app:config:import` runs **now**, on the live site. It is fast, safe and needed before the build so that static content deployment sees new store views or themes declared in `config.php`. When an upgrade will run, `setup:upgrade` covers the import.

`--skip-db-check` skips the whole phase: no status calls, no upgrade, no fingerprint update.

### Production mode

`deploy:mode:show` is checked; if the mode is not `production`, `deploy:mode:set production --skip-compilation` writes `env.php` only (no cleanup, no compilation). It happens before the build so the clone copies the final `env.php`.

### 5. Build (site live)

Skipped entirely with `--skip-di-compile --skip-static`; the clone is only created when something has to be built.

**Clone (in-place mode; in git mode the build directory already exists from the source phase).** `app`, `bin`, `lib`, `setup`, `vendor`, `composer.json` and `composer.lock` are cloned into `var/deploy/build`:

- Linux: `cp -al` (hardlinks; 160 000 vendor files take a few seconds, no extra disk space);
- macOS on APFS: `cp -Rpc` (copy-on-write clones);
- fallback: a plain recursive copy.

A hardlink shares the inode with the live file, so anything that rewrites a file **in place** inside the clone would change the live tree. Magento's compile and static content commands never write into `app/`, `lib/` or `vendor/`, but the files that *are* rewritten get **detached** (replaced by private copies): `app/etc/env.php`, `app/etc/config.php`, and before the autoload dump `vendor/composer/`, `vendor/autoload.php`, `app/etc/NonComposerComponentRegistration.php`.

The clone gets fresh, empty `generated/`, `var/` and `pub/static/`, and `pub/media` is a symlink to the live media directory (static content deployment only reads it). `bin/magento` of the clone resolves its root to the clone, so every path Magento uses (`generated/code`, `pub/static`, `var/view_preprocessed`, `var/cache`) lands in the clone. Module and theme registration files resolve to clone paths as well, which keeps Magento's path validator happy (a symlinked shadow root would fail there).

With `--skip-di-compile` but static deployment enabled, the live `generated/code` and `generated/metadata` are cloned in so static content is deployed against compiled code.

**Compile.** `setup:di:compile` runs in the clone, with one retry. Note that Magento's compiler cleans the configured cache backend at start (Redis included) exactly as it would in a classic deployment. Whatever the compiler leaves under `generated/` is treated as the result: `generated/code` is required, `generated/metadata` is optional, and additional directories such as `generated/staticcache` written by alternative compilers (for example `creatuity/magento2-interceptors`, which produces no `metadata` at all) are picked up automatically.

**Optimized autoloader.** `composer dump-autoload --optimize --apcu --no-plugins --working-dir=<clone>` builds the classmap against the freshly generated code. The result (`vendor/composer/`, `vendor/autoload.php`) is swapped into place together with `generated/` in the release phase. `--apcu` is harmless without the extension; `--no-plugins` avoids repeating plugin side effects that already happened during the live `composer install`.

**Static content.** A job list is built: every frontend theme × every frontend locale, plus the backend theme × every backend locale. Each job is one process:

```
php -d memory_limit=-1 var/deploy/build/bin/magento setup:static-content:deploy \
    --area=<area> --theme=<theme> --no-parent --force --max-execution-time=3600 [--no-js-bundle] [SCD_EXTRA_ARGS] <locale>
```

`--no-js-bundle` is added for `adminhtml`. The jobs run through `xargs -P $PARALLEL_JOBS`; on a terminal a live counter shows `n/m jobs`, otherwise each finished job prints a line. Every job writes its own log; after the phase they are merged into the main log in job order. Parallel locale deployments are safe because each locale writes to its own `pub/static/<area>/<theme>/<locale>/` directory; `deployed_version.txt` is written by every job and the last writer wins, which is fine because the version is only a cache-buster in URLs.

One failing job fails the build. The failing jobs are listed with their log paths, and nothing has been swapped, so the live site is untouched.

### 6. Release

The phase header says whether a maintenance window will be used and why.

1. **Database backup** (when `setup:upgrade` will run and `DB_BACKUP=true` or `DB_BACKUP_CMD` is set). It runs **before** the maintenance window so it does not add downtime. The built-in backup reads the credentials from `app/etc/env.php` (`host:port` notation supported) and writes a gzipped `mysqldump --single-transaction` into `var/backups/deploy_db_<timestamp>.sql.gz`.
2. **Maintenance mode** is enabled only when `setup:upgrade` will run (`MAINTENANCE=auto`) or when `MAINTENANCE=always`. `MAINTENANCE_ALLOWED_IPS` are passed as `--ip` options.
3. **Swap.** For every entry the live one is moved to `var/deploy/previous/<path>` and the built one is moved into place:
   - in git mode first the code: `app`, `bin`, `lib`, `setup`, `vendor`, `composer.json`, `composer.lock`, every other tracked top-level entry, and `pub/*` except `media` and `static`; tracked entries removed by the new commit are retired;
   - every entry under the build's `generated/` except `.htaccess` (`code`, `metadata`, `staticcache`, ...), `vendor/composer`, `vendor/autoload.php` (when compiled); live entries under `generated/` that the new compile did not produce are retired, so a stale `metadata` cannot survive a switch to another compiler;
   - `var/view_preprocessed` and every entry of the clone's `pub/static/` except `.htaccess` — normally `frontend`, `adminhtml`, `deployed_version.txt` (when static content was deployed);
   - `pub/static/_cache` (merged/minified bundles built from the old sources) is retired, it is regenerated on demand.
   Each swap is two renames; the gap between them is microseconds. If the second rename fails the previous version is restored immediately. The `.htaccess`, `pagespeed_cache` and any other custom entries under `pub/static` stay where they are. In git mode the live `.git` is then moved to the deployed commit with `git reset --mixed <commit>`, which updates `HEAD`, the branch and the index but writes nothing into the working tree (it already matches).
4. **`setup:upgrade --keep-generated --no-interaction`** runs when required. `--keep-generated` is correct here because the generated code was compiled from exactly this code in the build phase. On success the database fingerprint is stored.
5. **`cache:flush`** (a failure only warns).
6. **OPcache reset** via `OPCACHE_RESET_CMD`. With `opcache.validate_timestamps=0` php-fpm keeps serving the previous release from OPcache until it is reset or reloaded; without the command a reminder is printed.
7. **Maintenance mode** is disabled if it was enabled. The downtime is measured and printed in the summary.

### 7. Verify

- **Health check**: `curl` fetches `HEALTHCHECK_URL` (redirects followed) up to `HEALTHCHECK_RETRIES` times with `HEALTHCHECK_TIMEOUT` seconds each; anything but HTTP 2xx fails the deployment.
- **Post-deployment checks**: file counts of `generated/code`, `generated/metadata`, `pub/static`, presence of `pub/static/deployed_version.txt`, application mode, maintenance status.
- The previous artifacts in `var/deploy/previous` are deleted (kept with `--keep-previous`), and the build clone is removed.

### 8. Post-deploy hook

`POST_DEPLOY_CMD` runs in the Magento directory. A failure is only a warning because the deployment itself succeeded. Typical uses: cache warmers, notifications, Varnish purges.

### Summary and report

The terminal shows a green `DEPLOYMENT COMPLETE` banner with total duration and measured downtime, log and report paths, per-step timings, and counts of warnings and errors. A text report is written to `var/log/deploy_report_<timestamp>.txt` with configuration, git revision, step timings, and the errors and warnings extracted from the log.

---

## Zero-downtime model and its limits

What is and is not guaranteed, so nobody gets surprised:

- **No maintenance window without database changes.** Compile, static content, classmap and the swap all happen with the shop online.
- **Renames, not deletes.** The old `generated/` and `pub/static/` are never removed before the new ones exist. The swap itself is a series of `mv` calls that take milliseconds.
- **Static URLs keep working across the swap.** Magento serves `static/version<N>/…` through a rewrite that ignores the version, so pages cached in Varnish or the full page cache with the old version still resolve against the new files.
- **Git mode: the live tree changes only at the swap.** Code, vendor packages, generated code, classmap and static content are renamed into place one after another; the whole sequence takes milliseconds. A request that hits exactly that window may see a mix of old and new files. There is no state where new code runs against old generated code for minutes.
- **In-place mode has a window.** When you run `git pull` and `composer install` on the live docroot yourself, `app/` and `vendor/` are new while the previous `generated/` is still live, for the duration of the build. This window also exists with a classic deployment; only a class whose constructor signature changed *and* which has a generated interceptor or proxy can error during it. Use git mode or [pipeline mode](#pipeline-mode-build-once-release-elsewhere) to avoid it.
- **`setup:di:compile` clears the cache backend at start.** That is Magento's behaviour; the live site rebuilds its cache from unchanged configuration while the compile runs.
- **Vendor packages are swapped only in git mode.** In in-place mode `composer install` runs live and only the autoloader files under `vendor/composer` and `vendor/autoload.php` are part of the swap.
- **`pub/media` and `var/` are never touched**, in any mode. Tracked files under `pub/media` are not updated by the swap.
- **`setup:upgrade` always needs a window** in policy `auto`. Its duration is the downtime; the backup and the whole build are outside it.

---

## Failure handling and recovery

The script exits non-zero, prints a red `DEPLOYMENT FAILED` banner with the failed step and phase, the last 20 lines of the failed command's output, and a statement about the state of the live site:

| When it failed | State of the live site | What to do |
|---|---|---|
| Preflight, pre-deploy hook | Untouched. | Fix the reported problem, run again. |
| Source (git fetch, export) | Untouched. | Check the ref name, remote access, disk space. |
| Composer install | In-place mode: `vendor/` may be partially updated; generated code and static content are untouched. Git mode: untouched, everything happened in the build. | Run again (Composer resumes). |
| Database check, config import | Nothing swapped. | Read the command output in the log, run again. |
| Build (clone, compile, classmap, static content) | **Untouched.** The build clone stays in `var/deploy/build` for inspection and is removed by the next run. | Fix the cause (usually a code error), run again. |
| Release before `setup:upgrade` (swap failed) | The swap restores the previous entry when the second rename fails. | Check disk space and permissions, run again. |
| `setup:upgrade` | **Maintenance mode stays ENABLED.** New artifacts (and in git mode the new code) are live, the previous ones are in `var/deploy/previous`. | Fix the upgrade problem and run the deployment again, or restore manually: move each entry from `var/deploy/previous` back (for example `app`, `vendor`, `generated/code`, `pub/static/frontend`), in git mode `git reset --mixed <previous commit>`, then `bin/magento maintenance:disable`. A `DB_BACKUP` dump is in `var/backups/`. |
| Health check | Site is open but returned a non-2xx status; previous artifacts kept. | Inspect the site; restore from `var/deploy/previous` if needed. |
| Interrupted (Ctrl+C, SIGTERM) | Running child processes are killed; state as in the row matching the phase. | Same as above. |

Maintenance mode is intentionally **not** disabled automatically after a failed upgrade: a half-upgraded database should not be exposed blindly.

The lock is released on every exit path, so the next run never has to remove a stale lock after a crash (macOS PID locks detect dead processes).

---

## Policies: `DB_UPGRADE` and `MAINTENANCE`

| `DB_UPGRADE` | Behaviour |
|---|---|
| `auto` (default) | `setup:upgrade` runs when `setup:db:status` reports pending changes, when the database fingerprint changed, or when no fingerprint baseline exists yet. |
| `always` | Always run `setup:upgrade`. |
| `never` | Never run it; a warning is printed when changes were detected. The fingerprint is not updated. |

| `MAINTENANCE` | Behaviour |
|---|---|
| `auto` (default) | Maintenance mode only while `setup:upgrade` runs. Without an upgrade the release has no window at all. |
| `always` | The whole release phase (swap, upgrade, cache flush, OPcache reset) runs inside a window. Use it when a release must be atomic from the visitor's point of view. |
| `never` | Never touch maintenance mode, even for `setup:upgrade` (a warning is printed). |

`MAINTENANCE_ALLOWED_IPS` whitelists addresses during a window. `--skip-db-check` disables the upgrade regardless of `DB_UPGRADE`.

---

## Pipeline mode: build once, release elsewhere

The build phase produces plain files: `generated/` (all of it), `vendor/composer/`, `vendor/autoload.php`, `pub/static/`, `var/view_preprocessed/`. None of them contain absolute paths, so they can be built on a workstation or CI runner and released on the server.

```bash
# on the build machine (same commit, same composer.lock, same app/etc/config.php)
./deploy.sh --build-only                      # artifacts stay in var/deploy/build
./deploy.sh --push www@shop:/var/www/html     # build + rsync over SSH into <root>/var/deploy/incoming
./deploy.sh --push www@shop:/var/www/html --push-run   # ... and run the release on the server

# on the server
./deploy.sh --artifacts /var/www/html/var/deploy/incoming
```

`--artifacts` skips Composer and the build; the given directory is staged into `var/deploy/build` and released through the normal phases (database check, swap, `setup:upgrade` if needed, cache flush, OPcache reset, health check). Use `--skip-static` or `--skip-di-compile` when the artifacts intentionally contain only one of the two groups.

Constraints:

- The build machine must run the same commit with the same `composer.lock` and the same `app/etc/config.php` (module list).
- Static content settings that Magento reads from the database during `setup:static-content:deploy` (minification, merging, bundling, signing) must match production, or dump them into `config.php` with `app:config:dump`.
- Transfer size: `pub/static` for many themes and locales is gigabytes; `rsync` deltas help on repeated deployments.

---

## Configuration reference

Set in `.deploy.env` (KEY=VALUE, `#` comments, quotes optional) or the environment. Priority: **CLI flags > environment > `.deploy.env` > defaults**. The file is looked up in this order: `--config FILE`, `MAGENTO_DIR/.deploy.env`, the script directory, the current directory.

| Key | Default | Meaning |
|---|---|---|
| `MAGENTO_DIR` | `.` | Magento root. |
| `PHP_BIN` | `php` | PHP CLI binary. |
| `COMPOSER_BIN` | `composer` | Composer binary or phar; resolved to an absolute path. |
| `PHP_MEMORY_LIMIT` | `-1` | `memory_limit` for every PHP/Composer call; empty keeps `php.ini`. |
| `FRONTEND_THEMES` | `Magento/luma,Magento/blank` | Comma-separated frontend themes. |
| `FRONTEND_LANGUAGES` | `en_GB` | Frontend locales, space or comma separated. |
| `BACKEND_THEME` | `Magento/backend` | Backend theme. |
| `BACKEND_LANGUAGES` | `en_US` | Backend locales. |
| `PARALLEL_JOBS` | CPU cores | Static content processes running at once (capped at the core count). |
| `SCD_EXTRA_ARGS` | empty | Extra options appended to every `setup:static-content:deploy`. |
| `GIT_REF` | empty | Git mode: branch, tag or commit to deploy (`origin/main`, `v1.4.2`, a SHA, `@{upstream}`). Empty = in-place mode. |
| `GIT_REMOTE` | `origin` | Remote fetched before resolving `GIT_REF`. |
| `BUILD_COPY_VENDOR` | `false` | Copy the live `vendor/` into the build instead of hardlinking it. |
| `DB_UPGRADE` | `auto` | `auto`, `always`, `never`. |
| `MAINTENANCE` | `auto` | `auto`, `always`, `never`. |
| `MAINTENANCE_ALLOWED_IPS` | empty | IPs allowed during a window. |
| `BUILD_DIR` | `var/deploy` | Build, previous-artifacts and state directory. |
| `KEEP_PREVIOUS` | `false` | Keep `var/deploy/previous` after success. |
| `ARTIFACTS_DIR` | empty | Release pre-built artifacts from this directory (`--artifacts`). |
| `BUILD_ONLY` | `false` | Stop after the build (`--build-only`). |
| `PUSH_TARGET`, `PUSH_RUN` | empty, `false` | `--push`, `--push-run`. |
| `SKIP_COMPOSER`, `SKIP_DB_CHECK`, `SKIP_STATIC`, `SKIP_DI_COMPILE` | `false` | Skip phases. |
| `PRE_DEPLOY_CMD` | empty | Hook before any change; failure aborts. |
| `POST_DEPLOY_CMD` | empty | Hook after success; failure warns. |
| `OPCACHE_RESET_CMD` | empty | Runs right after the swap. Required with `opcache.validate_timestamps=0`. |
| `HEALTHCHECK_URL` | empty | URL expected to return HTTP 2xx after the release. |
| `HEALTHCHECK_RETRIES` | `3` | Attempts. |
| `HEALTHCHECK_TIMEOUT` | `30` | Seconds per attempt. |
| `DB_BACKUP` | `false` | Built-in mysqldump before `setup:upgrade`. |
| `DB_BACKUP_CMD` | empty | Custom backup command instead of mysqldump. |
| `LOG_FILE` | `var/log/deploy_<timestamp>.log` | Main log. |
| `LOG_RETENTION_DAYS` | `30` | Delete old logs, reports, backups (0 disables). |
| `VERBOSE`, `DRY_RUN`, `NO_INTERACTION` | `false` | As the flags. |
| `DEPLOY_ASCII` | `false` | ASCII symbols instead of Unicode. |
| `NO_COLOR` | unset | Disable colors (standard variable). |

All hook commands run with the Magento directory as working directory, through `bash -c`-style evaluation, so pipes and `&&` work.

---

## Command line reference

```
deploy.sh [OPTIONS]

-h, --help              Help
--init                  Configuration wizard: writes .deploy.env after reading themes and locales from the database
--config FILE           Config file to load
-d, --dir PATH          Magento root
-p, --php PATH          PHP binary
-c, --composer PATH     Composer binary
-j, --jobs NUM          Parallel static-content processes
--ref REF               Git mode: deploy this branch/tag/commit (fetches GIT_REMOTE first)
--git                   Git mode using the current branch's upstream
--db-upgrade MODE       auto | always | never
--maintenance MODE      auto | always | never
--memory-limit LIMIT    PHP memory_limit
--skip-composer         Skip composer install
--skip-db-check         Skip status checks and setup:upgrade
--skip-static           Keep current static content
--skip-di-compile       Keep current generated code and autoloader
--keep-previous         Keep replaced artifacts in var/deploy/previous
--build-only            Build, do not release
--artifacts DIR         Release pre-built artifacts from DIR
--push user@host:DIR    Build and rsync artifacts to the server (implies --build-only)
--push-run              After --push, run deploy.sh --artifacts on the server over ssh -t
--dry-run               Print every command, change nothing
--no-interaction        Never prompt
--ascii                 ASCII output
-v, --verbose           Stream command output, show debug lines
--log FILE              Main log path
--log-retention DAYS    Retention for logs/reports/backups
--frontend-themes T     Comma-separated themes
--backend-theme T
--frontend-langs L      Space/comma separated locales
--backend-langs L
```

Examples:

```bash
./deploy.sh --ref origin/main                 # fetch + deploy a commit, live checkout untouched until the swap
./deploy.sh --git                             # same, using the current branch's upstream
./deploy.sh                                   # code already in place
./deploy.sh --dry-run -v                      # preview, verbose
./deploy.sh -j 16                             # 16 static-content processes
./deploy.sh --skip-static --skip-di-compile   # code-only release (composer + db check + cache flush)
./deploy.sh --db-upgrade never                # first run on a host whose database is known to be current
./deploy.sh --maintenance always              # atomic release inside one window
./deploy.sh --build-only                      # produce artifacts only
./deploy.sh --push www@shop:/var/www/html --push-run
```

---

## Logs, reports and retention

- Main log: `var/log/deploy_<timestamp>.log`. Contains every message with level and timestamp, the full output of every command, the per-locale static content logs (merged after the phase), and `setup:db:status` / `app:config:status` output.
- Report: `var/log/deploy_report_<timestamp>.txt` (also on failure).
- Database backups: `var/backups/deploy_db_<timestamp>.sql.gz`.
- Retention: files older than `LOG_RETENTION_DAYS` are removed at the start of a run (`deploy_*.log`, `deploy_report_*.txt`, `deploy_*_scd` directories, `deploy_db_*.sql.gz`, and legacy `deployment_*.log` in the root). `0` disables.
- `var/deploy/db-fingerprint` holds the fingerprint of the last successful upgrade. Deleting it triggers exactly one extra `setup:upgrade`.

Add `var/deploy/` and `var/backups/` to `.gitignore` when the Magento root is a git checkout.

---

## Locking

Concurrent deployments are refused. Where `flock` exists the lock is a kernel lock on `var/.deploy.lock` and is released automatically when the process dies. Otherwise (stock macOS) a PID file is created atomically; a PID that no longer exists is treated as stale and replaced with a warning. `--dry-run` takes no lock.

---

## Terminal output

On a terminal the script prints phase headers, spinners with elapsed time for long commands, a live `n/m jobs` counter for static content, and a final summary with step timings and measured downtime. Colors follow `NO_COLOR`; Unicode symbols are used when the locale is UTF-8 and can be turned off with `--ascii` / `DEPLOY_ASCII=true`. Without a terminal (cron, CI) the same information is printed as plain lines, one per event, which keeps logs readable. `-v` streams the output of every command as it runs.

Example (abridged):

```
▸ Database check
  ✔ setup:db:status: module versions up to date
  ✔ app:config:status: configuration up to date
  ✔ Database fingerprint unchanged (no new schema or patches)
    setup:upgrade skipped - no database changes
▸ Build  site live, building in var/deploy/build
  ✔ Cloned code tree into var/deploy/build (hardlink)  4s
  ✔ setup:di:compile  2m 41s
  ✔ composer dump-autoload --optimize --apcu (build)  21s
  ✔ Static content: 84 jobs on 16 cores  6m 12s · slowest: frontend Vendor/theme de_DE 1m 48s
▸ Release  zero downtime: no maintenance window needed
  ✔ Swapped 7 artifacts into place: generated/code generated/metadata vendor/composer vendor/autoload.php var/view_preprocessed pub/static/adminhtml pub/static/deployed_version.txt pub/static/frontend  0s
  ✔ cache:flush  3s
  ✔ opcache reset: sudo systemctl reload php8.3-fpm  1s
▸ Verify
  ✔ Health check: https://www.example.com/ → HTTP 200  (attempt 1, 1s)

   DEPLOYMENT COMPLETE    in 9m 40s · downtime 0s
```

---

## Testing

`scripts/test-deploy.sh` runs the script against a throw-away sandbox with stub `php`, `composer`, `curl`, `mysqldump`, `ssh` and `rsync` binaries. The fake `bin/magento` resolves its root from the invoked path, so the tests prove that compile and static content really run in the clone, that the live tree is untouched on failures, that the swap, the fingerprint logic, the policies, hooks, backup, health check, pipeline mode and locking behave as documented. It never touches a real store, database or network.

```bash
bash scripts/test-deploy.sh
```

CI (`.github/workflows/ci.yml`) runs ShellCheck, the test suite on Ubuntu (flock, hardlinks) and macOS (PID lock, APFS clones, Bash 3.2), and an installation from the pushed commit.

---

## Troubleshooting

**`include(...generated/code/.../Proxy.php): Failed to open stream` right after Composer.** An optimized classmap referenced generated files that Magento deleted because `var/.regenerate` existed. Version 3 never dumps an optimized classmap on the live tree and removes the flag before the first `bin/magento` call. Run the deployment again; the plain autoloader regenerates missing proxies on demand.

**`BUILD_DIR is on a different filesystem`.** Renames and hardlinks need one filesystem. Set `BUILD_DIR` to a directory on the same mount as `pub/` and `generated/`.

**The first run enters maintenance mode although nothing changed.** No fingerprint baseline existed yet. Run once with `--db-upgrade never` if the database is known to be current; the baseline is written on the next real upgrade.

**Static content jobs run out of memory.** Lower `-j` / `PARALLEL_JOBS`; each process needs roughly 700 MB. The preflight warns when the configured jobs exceed available memory.

**`Path "..." cannot be used with directory "..."` during static content deployment.** A module or theme is registered from a path outside the Magento root (symlinked module). Move it inside the root; the build clone requires real files or hardlinks, not symlinks to other locations.

**The shop still serves old code after the release.** php-fpm runs with `opcache.validate_timestamps=0`. Set `OPCACHE_RESET_CMD` (`cachetool opcache:reset`, or a php-fpm reload).

**Maintenance mode is still on after a failure.** That is intentional after a failed `setup:upgrade`. Fix, rerun or restore from `var/deploy/previous`, then `bin/magento maintenance:disable`.

**Git mode: `Live checkout has N locally modified tracked file(s)`.** Someone edited files on the server. The release replaces them with the committed versions and keeps the old ones in `var/deploy/previous`. Commit or discard those edits first if they matter.

**Git mode: a file under `app/` or `pub/` disappeared after the release.** It was untracked and not ignored inside a swapped directory, and `git ls-files --others` did not list it because a `.gitignore` pattern excluded it while another pattern such as an unanchored `vendor/` also matched a path like `app/code/Vendor`. Anchor such patterns (`/vendor/`); the previous copy is in `var/deploy/previous`.

**Merged CSS/JS looks stale.** `pub/static/_cache` is retired on every static deployment; if you run with `--skip-static`, remove it manually or flush the static files cache in the admin.

---

## License

MIT, see [LICENSE](LICENSE).

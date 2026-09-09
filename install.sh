#!/usr/bin/env bash
# ===================================================================
# Installer for deploy.sh (Magento 2 zero-downtime deployment)
# https://github.com/hryvinskyi/magento2-deployment
#
# Usage (run inside the Magento root):
#   curl -fsSL https://raw.githubusercontent.com/hryvinskyi/magento2-deployment/main/install.sh | bash
#
# Options (pass after "bash -s --"):
#   curl -fsSL .../install.sh | bash -s -- --dir /var/www/html --ref v3.0.0
#
#   --dir PATH     Magento root to install into (default: current directory)
#   --ref REF      Git branch, tag or commit to install (default: main)
#   --no-config    Do not download .deploy.env.example
#   -h, --help     Show this help
#
# Environment: MAGENTO_DIR, DEPLOY_REF have the same meaning as the options.
# Re-running the installer updates deploy.sh in place; the previous copy is
# kept as deploy.sh.bak when it differs.
# ===================================================================
set -euo pipefail

REPO="hryvinskyi/magento2-deployment"
REF="${DEPLOY_REF:-main}"
TARGET_DIR="${MAGENTO_DIR:-$PWD}"
WITH_CONFIG=true

usage() {
    sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)       [[ $# -ge 2 ]] || { echo "Option --dir requires a value" >&2; exit 1; }; TARGET_DIR="$2"; shift 2 ;;
        --ref)       [[ $# -ge 2 ]] || { echo "Option --ref requires a value" >&2; exit 1; }; REF="$2"; shift 2 ;;
        --no-config) WITH_CONFIG=false; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# DEPLOY_BASE_URL overrides the download location (tests, mirrors)
BASE_URL="${DEPLOY_BASE_URL:-https://raw.githubusercontent.com/$REPO/$REF}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else
    B="" G="" Y="" R="" N=""
fi
info() { echo "${G}+${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
fail() { echo "${R}x${N} $*" >&2; exit 1; }

# ── Prerequisites ──────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q "$1" -O "$2"; }
else
    fail "curl or wget is required"
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    fail "Target directory does not exist: $TARGET_DIR (use --dir PATH)"
fi
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if [[ ! -f "$TARGET_DIR/bin/magento" ]]; then
    warn "$TARGET_DIR does not look like a Magento root (bin/magento not found)"
    warn "deploy.sh is installed anyway; run it with --dir /path/to/magento or set MAGENTO_DIR in .deploy.env"
fi

echo "${B}Installing deploy.sh${N} ($REPO@$REF) into $TARGET_DIR"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── deploy.sh ──────────────────────────────────────────────────────
fetch "$BASE_URL/deploy.sh" "$TMP/deploy.sh" || fail "Download failed: $BASE_URL/deploy.sh"
bash -n "$TMP/deploy.sh" || fail "Downloaded deploy.sh does not pass a bash syntax check"
grep -q 'DEPLOY_VERSION=' "$TMP/deploy.sh" || fail "Downloaded file does not look like deploy.sh"

VERSION="$(sed -n 's/^DEPLOY_VERSION="\([^"]*\)".*/\1/p' "$TMP/deploy.sh" | head -1)"

if [[ -f "$TARGET_DIR/deploy.sh" ]]; then
    if cmp -s "$TARGET_DIR/deploy.sh" "$TMP/deploy.sh"; then
        info "deploy.sh v${VERSION:-?} is already up to date"
    else
        cp -p "$TARGET_DIR/deploy.sh" "$TARGET_DIR/deploy.sh.bak"
        warn "Existing deploy.sh saved as deploy.sh.bak"
    fi
fi

install -m 0755 "$TMP/deploy.sh" "$TARGET_DIR/deploy.sh"
info "deploy.sh v${VERSION:-?} installed"

# ── Example configuration ──────────────────────────────────────────
if [[ "$WITH_CONFIG" == "true" ]]; then
    if fetch "$BASE_URL/.deploy.env.example" "$TMP/.deploy.env.example" 2>/dev/null; then
        install -m 0644 "$TMP/.deploy.env.example" "$TARGET_DIR/.deploy.env.example"
        info ".deploy.env.example installed"
    else
        warn "Could not download .deploy.env.example (skipped)"
    fi
fi

# ── Smoke test ─────────────────────────────────────────────────────
"$TARGET_DIR/deploy.sh" --help >/dev/null 2>&1 || fail "deploy.sh --help failed"

echo
echo "${B}Next steps${N}"
echo "  cd $TARGET_DIR"
if [[ -f "$TARGET_DIR/.deploy.env" ]]; then
    echo "  ./deploy.sh --dry-run        # preview with the existing .deploy.env"
else
    echo "  ./deploy.sh --init           # generate .deploy.env from your Magento installation"
    echo "  ./deploy.sh --dry-run        # preview"
fi
echo "  ./deploy.sh                  # zero-downtime deployment"
echo
echo "Documentation: https://github.com/$REPO"

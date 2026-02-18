#!/usr/bin/env bash
# install-marketplace.sh - Install ESBMC marketplace for Claude Code
#
# The ESBMC repository is large (~20,000 files, ~70MB) which can cause
# the standard `/plugin marketplace add esbmc/esbmc` command to fail on
# systems with limited memory (particularly macOS) due to the full git
# clone that Claude Code performs.
#
# This script works around the issue by performing a shallow, sparse
# checkout that only fetches the files needed for the marketplace plugin.

set -euo pipefail

MARKETPLACE_NAME="esbmc-marketplace"
MARKETPLACE_DIR="${HOME}/.claude/plugins/marketplaces/${MARKETPLACE_NAME}"
REPO_URL="https://github.com/esbmc/esbmc.git"

# Paths needed for the marketplace plugin
SPARSE_PATHS=(".claude-plugin" "claude-plugin")

usage() {
    echo "Usage: $0 [--force]"
    echo ""
    echo "Install the ESBMC marketplace for Claude Code using a lightweight"
    echo "shallow clone (avoids memory issues with large repositories)."
    echo ""
    echo "Options:"
    echo "  --force    Remove existing marketplace and reinstall"
    echo "  --help     Show this help message"
}

main() {
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    # Check for git
    if ! command -v git &>/dev/null; then
        echo "Error: git is required but not found in PATH" >&2
        exit 1
    fi

    # Check if marketplace already exists
    if [[ -d "${MARKETPLACE_DIR}" ]]; then
        if [[ "${force}" == "true" ]]; then
            echo "Removing existing marketplace at ${MARKETPLACE_DIR}..."
            rm -rf "${MARKETPLACE_DIR}"
        else
            echo "Error: Marketplace already exists at ${MARKETPLACE_DIR}" >&2
            echo "Use --force to remove and reinstall" >&2
            exit 1
        fi
    fi

    # Create parent directory
    mkdir -p "$(dirname "${MARKETPLACE_DIR}")"

    echo "Cloning ESBMC marketplace (shallow + sparse)..."

    # Perform a shallow clone with no checkout, then sparse-checkout only
    # the directories needed for the marketplace plugin.
    git clone \
        --depth 1 \
        --filter=blob:none \
        --sparse \
        "${REPO_URL}" \
        "${MARKETPLACE_DIR}"

    cd "${MARKETPLACE_DIR}"

    # Configure sparse-checkout to only include marketplace/plugin files
    git sparse-checkout set "${SPARSE_PATHS[@]}"

    echo ""
    echo "ESBMC marketplace installed successfully!"
    echo ""
    echo "You can now install the plugin in Claude Code:"
    echo "  /plugin install esbmc-plugin@esbmc-marketplace"
    echo ""
    echo "To update later:"
    echo "  /plugin marketplace update esbmc-marketplace"
}

main "$@"

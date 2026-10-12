#!/usr/bin/env bash
# =============================================================================
# DSH (DeepSeek Harness) Post-Install Setup Script
# =============================================================================
# This script reinstalls all custom packages, skills, and configurations
# on a fresh DSH instance running in Docker (ghcr.io/smanx/deepseek-harness:admin-latest).
#
# Usage:
#   docker exec -it <container_name> bash /root/setup-dsh.sh
#   OR mount this script into the container and run it.
#
# What it installs:
#   - System packages: tesseract-ocr, ffmpeg, libreoffice, poppler-utils
#   - Python packages: openpyxl, pdfplumber, mammoth, pdf2image, etc.
#   - Global npm packages: docx, @firecrawl/anydoc
#   - DSH market plugins: dsh-better-sidebar, dsh-mobile-hanui, dshmarket
#   - DSH settings: LLM provider config, agent defaults
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[✗]${NC} $*"; }
header() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Detect environment
# ---------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
else
    OS_ID="unknown"
fi

header "Environment Detection"
log "OS: ${OS_ID} ($(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"'))"
log "Home: ${HOME}"
log "DSH install dir: /opt/dsh"
log "DSH data dir: ${HOME}/.dsh"

# ---------------------------------------------------------------------------
# 1. System packages (apt)
# ---------------------------------------------------------------------------
header "System Packages (apt)"

if command -v apt-get &>/dev/null; then
    log "Updating apt package lists..."
    apt-get update -qq 2>/dev/null || warn "apt update had warnings"

    SYSTEM_PACKAGES=(
        tesseract-ocr
        tesseract-ocr-eng
        tesseract-ocr-osd
        ffmpeg
        libreoffice-writer
        libreoffice-calc
        libreoffice-impress
        libreoffice-common
        libreoffice-core
        poppler-utils
        poppler-data
    )

    log "Installing system packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${SYSTEM_PACKAGES[@]}" 2>/dev/null || {
        warn "Some system packages may have failed, continuing..."
    }

    log "System packages installed."
else
    warn "apt-get not found, skipping system package installation."
fi

# ---------------------------------------------------------------------------
# 2. Python packages (pip)
# ---------------------------------------------------------------------------
header "Python Packages (pip)"

if command -v pip &>/dev/null || command -v pip3 &>/dev/null; then
    PIP=$(command -v pip3 || command -v pip)

    PYTHON_PACKAGES=(
        # Document processing
        mammoth
        python-pptx
        openpyxl
        xlrd
        xlsxwriter
        pypdf
        pypdfium2
        pdfminer.six
        pdfplumber
        pdf2image
        reportlab

        # Text/markup processing
        beautifulsoup4
        markdownify
        markitdown
        lxml

        # Data processing
        pandas
        numpy

        # Speech / media
        SpeechRecognition
        pydub

        # OCR
        pytesseract

        # Azure / AI
        azure-ai-documentintelligence
        azure-ai-contentunderstanding
        azure-core
        azure-identity
        msal
        msal-extensions

        # Utilities
        requests
        python-dotenv
        defusedxml
        cobble
    )

    log "Installing ${#PYTHON_PACKAGES[@]} Python packages..."
    $PIP install --quiet --break-system-packages "${PYTHON_PACKAGES[@]}" 2>/dev/null || {
        warn "Retrying without --break-system-packages..."
        $PIP install --quiet "${PYTHON_PACKAGES[@]}" 2>/dev/null || warn "Some Python packages may have failed."
    }

    log "Python packages installed."
else
    warn "pip not found, skipping Python package installation."
fi

# ---------------------------------------------------------------------------
# 3. Global npm packages
# ---------------------------------------------------------------------------
header "Global npm Packages"

if command -v npm &>/dev/null; then
    NPM_GLOBAL_PACKAGES=(
        docx
        "@firecrawl/anydoc"
    )

    log "Installing ${#NPM_GLOBAL_PACKAGES[@]} global npm packages..."
    for pkg in "${NPM_GLOBAL_PACKAGES[@]}"; do
        npm install -g "$pkg" --loglevel=warn 2>/dev/null && log "  ✓ $pkg" || warn "  ✗ $pkg failed"
    done

    log "Global npm packages installed."
else
    warn "npm not found, skipping npm package installation."
fi

# ---------------------------------------------------------------------------
# 4. DSH settings (settings.yaml)
# ---------------------------------------------------------------------------
header "DSH Settings"

DSH_HOME="${HOME}/.dsh"
SETTINGS_FILE="${DSH_HOME}/settings.yaml"

if [ -f "$SETTINGS_FILE" ]; then
    log "settings.yaml already exists, keeping your current model provider settings."
else
    log "No existing settings.yaml found. You can configure your provider via Settings → Models in the Web UI."
fi

# ---------------------------------------------------------------------------
# 5. DSH web profile packages (market plugins)
# ---------------------------------------------------------------------------
header "DSH Web Profile Plugins"

WEB_PROFILE="${DSH_HOME}/profiles/web"

if [ -d "$WEB_PROFILE" ]; then
    log "Updating web profile package.json with market plugins..."

    # Ensure package.json has the right dependencies
    cat > "${WEB_PROFILE}/package.json" << 'PKGJSON_EOF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "dsh-better-sidebar": "^0.19.0",
    "dsh-mobile-hanui": "^0.2.5",
    "dshmarket": "^1.45.1"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "dshmarket",
        "dsh-better-sidebar",
        "dsh-mobile-hanui"
      ],
      "patchReload": "live"
    }
  }
}
PKGJSON_EOF

    log "Installing web profile dependencies..."
    cd "$WEB_PROFILE"
    if command -v pnpm &>/dev/null; then
        pnpm install --no-frozen-lockfile 2>/dev/null && log "pnpm install completed" || warn "pnpm install had issues"
    elif command -v npm &>/dev/null; then
        npm install 2>/dev/null && log "npm install completed" || warn "npm install had issues"
    fi
    cd /
else
    warn "Web profile directory not found at ${WEB_PROFILE}"
fi

# ---------------------------------------------------------------------------
# 6. Ensure cordis.patch.yml exists (empty array = no patches)
# ---------------------------------------------------------------------------
header "DSH Profile Patches"

CORDIS_PATCH="${WEB_PROFILE}/cordis.patch.yml"
if [ ! -f "$CORDIS_PATCH" ]; then
    mkdir -p "$(dirname "$CORDIS_PATCH")"
    echo '# Your patch layer for this dsh profile, applied after every bundle layer:' > "$CORDIS_PATCH"
    echo '# a top-level YAML array of loader patch entries.' >> "$CORDIS_PATCH"
    echo '[]' >> "$CORDIS_PATCH"
    log "Created empty cordis.patch.yml"
else
    log "cordis.patch.yml already exists"
fi

# ---------------------------------------------------------------------------
# 7. Verify installations
# ---------------------------------------------------------------------------
header "Verification"

PASS=0
FAIL=0

check() {
    if eval "$2" &>/dev/null; then
        log "  ✓ $1"
        PASS=$((PASS + 1))
    else
        err "  ✗ $1"
        FAIL=$((FAIL + 1))
    fi
}

check "tesseract-ocr"    "tesseract --version"
check "ffmpeg"            "ffmpeg -version"
check "libreoffice"       "libreoffice --version"
check "poppler-utils"     "pdftotext -v"
check "Python: openpyxl"  "python3 -c 'import openpyxl'"
check "Python: pdfplumber" "python3 -c 'import pdfplumber'"
check "Python: mammoth"   "python3 -c 'import mammoth'"
check "Python: pandas"    "python3 -c 'import pandas'"
check "Python: pypdf"     "python3 -c 'import pypdf'"
check "npm: docx"         "node -e \"require('docx')\""
check "npm: anydoc"       "node -e \"require('@firecrawl/anydoc')\""

header "Setup Complete"
log "Passed: ${PASS} / $((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    warn "${FAIL} checks failed. You may need to install those manually."
fi

echo ""
log "Next steps:"
echo "  1. Restart the DSH service or container to load new plugins."
echo "  2. Access the web UI and configure your model provider in Settings → Models if not done already."
echo ""

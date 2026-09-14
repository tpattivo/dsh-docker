#!/usr/bin/env bash
#
# install-doc-deps.sh
#
# One-shot global installer for the document skills' dependencies:
#   - xlsx : openpyxl, pandas, markitdown, xlsxwriter/xlrd, LibreOffice, markitdown CLI
#   - docx : npm "docx", pandoc, LibreOffice, pdftoppm (for render verification)
#   - pdf  : pypdf, pdfplumber, reportlab, pytesseract, pdf2image, poppler-utils,
#            qpdf, tesseract-ocr, ffmpeg
#
# Target environment: Debian 12 (bookworm), x86_64, running as root.
# Deliberately NOT cross-distro / cross-platform. Matches the DSH sandbox this
# was written in: Node at /usr/local, npm prefix /usr/local, no pre-existing pip,
# and a PEP 668 "EXTERNALLY-MANAGED" system Python 3.11.
#
# Usage:
#   ./install-doc-deps.sh              # install everything (idempotent)
#   ./install-doc-deps.sh --verify-only  # only check what is already present
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

APT_PACKAGES=(
  python3-pip
  libreoffice-writer
  libreoffice-calc
  libreoffice-impress
  pandoc
  poppler-utils
  qpdf
  tesseract-ocr
  fonts-liberation
  ffmpeg
)

# system-wide Python packages (PEP 668 -> --break-system-packages)
PIP_PACKAGES=(
  openpyxl
  pandas
  "markitdown[all]"
  pypdf
  pdfplumber
  reportlab
  pytesseract
  pdf2image
)

NPM_PACKAGES=(
  docx
)

# Node does not search the npm global root for require() by default, but it does
# search the legacy global folder below. Symlinking it makes `require('docx')`
# work from any cwd, which is what the docx skill relies on.
NODE_GLOBAL_ROOT="$(npm root -g 2>/dev/null || echo /usr/local/lib/node_modules)"
NODE_LEGACY_LINK="/usr/local/lib/node"

VERIFY_ONLY=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (global installs go to /usr and /usr/local)"
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

apt_install() {
  log "apt: updating package lists"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  log "apt: installing system tools"
  local missing=()
  local pkg
  for pkg in "${APT_PACKAGES[@]}"; do
    # dpkg-query returns non-zero when the package is not installed
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "all apt packages already present"
    return 0
  fi

  printf '  installing: %s\n' "${missing[*]}"
  apt-get install -y -qq "${missing[@]}"
  ok "apt packages installed"
}

pip_install() {
  log "pip: installing Python packages system-wide"

  if ! python3 -m pip --version >/dev/null 2>&1; then
    # Should have been handled by apt_install, but be explicit.
    die "pip is still unavailable after 'apt-get install python3-pip'"
  fi

  # --break-system-packages is required: Debian marks this Python EXTERNALLY-MANAGED.
  python3 -m pip install \
    --break-system-packages \
    --no-input \
    --disable-pip-version-check \
    --upgrade "${PIP_PACKAGES[@]}"

  ok "pip packages installed"
}

npm_install() {
  log "npm: installing global Node packages"

  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not found; installing nodejs/npm from apt"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq nodejs npm
  fi

  npm install -g "${NPM_PACKAGES[@]}"
  ok "npm packages installed ($(npm root -g))"
}

link_node_global() {
  log "node: exposing global modules to require()"

  if [ -L "$NODE_LEGACY_LINK" ]; then
    if [ "$(readlink -f "$NODE_LEGACY_LINK")" = "$(readlink -f "$NODE_GLOBAL_ROOT")" ]; then
      ok "$NODE_LEGACY_LINK already points at $NODE_GLOBAL_ROOT"
      return 0
    fi
    warn "replacing wrong symlink $NODE_LEGACY_LINK"
    rm -f "$NODE_LEGACY_LINK"
  elif [ -e "$NODE_LEGACY_LINK" ]; then
    warn "$NODE_LEGACY_LINK exists as a real directory; leaving it untouched"
    warn "if 'require(\"docx\")' fails, set NODE_PATH=$NODE_GLOBAL_ROOT instead"
    return 0
  fi

  ln -sfn "$NODE_GLOBAL_ROOT" "$NODE_LEGACY_LINK"
  ok "symlinked $NODE_LEGACY_LINK -> $NODE_GLOBAL_ROOT"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify() {
  log "verifying installation"
  local failed=0

  echo "  -- Python modules"
  python3 - <<'PY' || failed=1
import importlib
mods = ["openpyxl", "pandas", "markitdown", "pdfminer", "xlrd", "xlsxwriter",
        "pypdf", "pdfplumber", "reportlab", "pytesseract", "pdf2image"]
bad = []
for m in mods:
    try:
        mod = importlib.import_module(m)
        ver = getattr(mod, "__version__", "") or getattr(mod, "Version", "")
        print(f"  OK   {m:14} {ver}")
    except Exception as e:
        bad.append(m)
        print(f"  FAIL {m:14} {e}")
raise SystemExit(1 if bad else 0)
PY

  echo "  -- CLI tools"
  local c p
  for c in markitdown soffice pandoc pdftotext pdfimages pdftoppm qpdf tesseract ffmpeg; do
    if p="$(command -v "$c")"; then
      printf '  OK   %-12s %s\n' "$c" "$p"
    else
      printf '  FAIL %-12s not found\n' "$c"
      failed=1
    fi
  done

  echo "  -- npm global packages"
  local pkg
  for pkg in "${NPM_PACKAGES[@]}"; do
    if node -e "require('$pkg')" >/dev/null 2>&1; then
      printf '  OK   %-12s require() works from an arbitrary cwd\n' "$pkg"
    else
      printf '  FAIL %-12s require() failed\n' "$pkg"
      failed=1
    fi
  done

  if [ "$failed" -eq 0 ]; then
    printf '\n\033[1;32mAll dependencies present and working.\033[0m\n'
  else
    printf '\n\033[1;31mSome dependencies are missing or broken (see FAIL above).\033[0m\n' >&2
    return 1
  fi
}

usage() {
  cat <<'EOF'
install-doc-deps.sh — global installer for the xlsx / docx / pdf skill deps.

Target environment: Debian 12 (bookworm), x86_64, run as root.
Installs into /usr (apt), the system Python (pip), and the npm global root.

Usage:
  ./install-doc-deps.sh                install everything (idempotent)
  ./install-doc-deps.sh --verify-only  only check what is already present
  ./install-doc-deps.sh --help         show this help

Installs:
  apt  : python3-pip, libreoffice-{writer,calc,impress}, pandoc, poppler-utils,
         qpdf, tesseract-ocr, fonts-liberation, ffmpeg
  pip  : openpyxl, pandas, markitdown[all], pypdf, pdfplumber, reportlab,
         pytesseract, pdf2image
  npm  : docx   (+ symlinks /usr/local/lib/node so require('docx') works anywhere)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verify-only) VERIFY_ONLY=1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify
    return
  fi

  require_root
  apt_install
  pip_install
  npm_install
  link_node_global

  printf '\n'
  verify
}

main "$@"

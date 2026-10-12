#!/usr/bin/env bash
# =============================================================================
# Install DSH Agent Preset (e.g., HR-mode) into the DSH web profile
# =============================================================================
# Usage inside container:
#   bash /opt/dsh-config/install-preset.sh [preset-name]
#   OR
#   docker exec -it <container_name> bash -c "dsh plugin --profile web add -w /opt/dsh-config/presets/hr-mode"
# =============================================================================

set -euo pipefail

PRESET_NAME="${1:-hr-mode}"
MOUNTED_DIR="/opt/dsh-config/presets/${PRESET_NAME}"
PERSISTENT_DIR="/root/.dsh/presets/${PRESET_NAME}"

echo "=================================================="
echo " Installing Agent Preset: ${PRESET_NAME}"
echo "=================================================="

# 1. Ensure directory exists in persistent storage (/root/.dsh/presets)
if [ -d "${MOUNTED_DIR}" ]; then
  echo "[✓] Found preset in mounted directory: ${MOUNTED_DIR}"
  mkdir -p "/root/.dsh/presets"
  cp -r "${MOUNTED_DIR}" "/root/.dsh/presets/"
  echo "[✓] Copied to persistent volume at: ${PERSISTENT_DIR}"
  INSTALL_PATH="${PERSISTENT_DIR}"
elif [ -d "${PERSISTENT_DIR}" ]; then
  echo "[✓] Found preset in persistent storage: ${PERSISTENT_DIR}"
  INSTALL_PATH="${PERSISTENT_DIR}"
else
  echo "[✗] Preset directory not found in ${MOUNTED_DIR} or ${PERSISTENT_DIR}"
  exit 1
fi

# 2. Add preset to DSH web profile as a workspace bundle
echo "[✓] Registering preset bundle in web profile..."
dsh plugin --profile web add -w "${INSTALL_PATH}"

echo ""
echo "[✓] Preset '${PRESET_NAME}' successfully installed!"
echo "--------------------------------------------------"
echo "Next steps:"
echo "  1. Restart DSH service (via https://your-domain/__admin/ or 'docker restart <container>')"
echo "  2. In Telegram, switch to HR mode:"
echo "       /preset hr-mode"
echo "  3. Start a new session:"
echo "       /new"
echo "=================================================="

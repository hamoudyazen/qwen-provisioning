#!/usr/bin/env bash
set -euo pipefail

echo "Qwen-Image-2512 provisioning: starting"

# Vast's ComfyUI Serverless image must supply this path.
COMFY_DIR="${COMFYUI_DIR:-/opt/workspace-internal/ComfyUI}"

if [[ ! -d "$COMFY_DIR/models" ]]; then
  echo "ERROR: ComfyUI models directory not found at: $COMFY_DIR/models" >&2
  echo "Set COMFYUI_DIR to the actual ComfyUI installation directory." >&2
  exit 1
fi

echo "ComfyUI models directory verified: $COMFY_DIR/models"
echo "Provisioning preflight passed. Model download stage not enabled yet."

#!/usr/bin/env bash
set -euo pipefail

echo "=== Qwen-Image-2512 provisioning ==="

# Vast base-image ComfyUI installations use /workspace/ComfyUI.
# Keep an override and a fallback for images that expose the internal path.
if [[ -n "${COMFYUI_DIR:-}" && -d "${COMFYUI_DIR}/models" ]]; then
  COMFY_DIR="$COMFYUI_DIR"
elif [[ -d /workspace/ComfyUI/models ]]; then
  COMFY_DIR="/workspace/ComfyUI"
elif [[ -d /opt/workspace-internal/ComfyUI/models ]]; then
  COMFY_DIR="/opt/workspace-internal/ComfyUI"
else
  echo "ERROR: Could not find ComfyUI/models." >&2
  echo "Checked /workspace/ComfyUI and /opt/workspace-internal/ComfyUI." >&2
  echo "Set COMFYUI_DIR to the correct ComfyUI directory if needed." >&2
  exit 1
fi

export COMFY_DIR
echo "Using ComfyUI directory: $COMFY_DIR"

# Activate Vast's standard Python environment when present.
if [[ -f /venv/main/bin/activate ]]; then
  # shellcheck disable=SC1091
  source /venv/main/bin/activate
fi

: "${R2_ENDPOINT_URL:?Missing R2_ENDPOINT_URL}"
: "${R2_BUCKET:?Missing R2_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?Missing AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Missing AWS_SECRET_ACCESS_KEY}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but was not found." >&2
  exit 1
fi

if ! python -c "import boto3" >/dev/null 2>&1; then
  python -m pip install --no-cache-dir boto3
fi

python - <<'PY'
import os
import subprocess
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

comfy = Path(os.environ["COMFY_DIR"])
bucket = os.environ["R2_BUCKET"]
prefix = "qwen-image-2512/"

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["R2_ENDPOINT_URL"],
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name=os.getenv("AWS_DEFAULT_REGION", "auto"),
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)

models = [
    (
        "diffusion_models",
        "qwen_image_2512_fp8_e4m3fn.safetensors",
        "https://huggingface.co/Comfy-Org/Qwen-Image/resolve/main/split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors",
    ),
    (
        "text_encoders",
        "qwen_2.5_vl_7b_fp8_scaled.safetensors",
        "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
    ),
    (
        "vae",
        "qwen_image_vae.safetensors",
        "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors",
    ),
]

def object_exists(key: str) -> bool:
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        code = exc.response.get("Error", {}).get("Code")
        if status == 404 or code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise

for folder, filename, url in models:
    directory = comfy / "models" / folder
    directory.mkdir(parents=True, exist_ok=True)

    destination = directory / filename
    temporary = destination.with_name(destination.name + ".part")
    key = prefix + folder + "/" + filename

    if destination.is_file() and destination.stat().st_size > 0:
        print(f"Already present locally: {filename}", flush=True)
        continue

    if object_exists(key):
        print(f"Found in R2; downloading {filename}", flush=True)
        s3.download_file(bucket, key, str(temporary))
    else:
        print(f"Not in R2; downloading from Hugging Face: {filename}", flush=True)
        subprocess.run(
            [
                "curl", "--fail", "--location",
                "--retry", "8", "--retry-delay", "3", "--retry-all-errors",
                "--continue-at", "-", "--output", str(temporary), url,
            ],
            check=True,
        )
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise RuntimeError(f"Download produced an empty file: {filename}")

        print(f"Uploading {filename} to R2", flush=True)
        s3.upload_file(str(temporary), bucket, key)

    if not temporary.is_file() or temporary.stat().st_size == 0:
        raise RuntimeError(f"Model file is missing or empty: {filename}")

    temporary.replace(destination)
    print(f"Ready: {destination} ({destination.stat().st_size:,} bytes)", flush=True)

print("=== All Qwen-Image-2512 model files are ready ===", flush=True)

# Provisioning can run after Supervisor starts. Refresh ComfyUI if it is
# already running so its model loaders discover the newly installed weights.
if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui >/dev/null 2>&1; then
  supervisorctl restart comfyui
fi

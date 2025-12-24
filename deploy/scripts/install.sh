cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

# ============================================
# MetalGPT Install v3 (reproducible, 2 venvs)
# - backend-venv (FastAPI)
# - vllm-venv (vLLM from GitHub + auto torch)
# ============================================

APP_DIR="/opt/metalgpt"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKEND_VENV="${APP_DIR}/backend-venv"
VLLM_VENV="${APP_DIR}/vllm-venv"

MODEL_DIR="${MODEL_DIR:-/opt/models/MetalGPT-1}"
HF_CACHE="${APP_DIR}/hf_cache"

DOMAIN="${DOMAIN:-metal-gpt.ru}"
ENABLE_NGINX="${ENABLE_NGINX:-1}"
ENABLE_REDIS="${ENABLE_REDIS:-1}"

# Torch wheels index URL (CUDA build)
# Common values:
#  - cu121: https://download.pytorch.org/whl/cu121
#  - cu124: https://download.pytorch.org/whl/cu124
#  - cpu:   https://download.pytorch.org/whl/cpu
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"

# Reproducibility controls
REBUILD_VENVS="${REBUILD_VENVS:-1}"   # 1 = delete & recreate venvs every run
VLLM_GIT_REF="${VLLM_GIT_REF:-main}"  # vLLM git ref (branch/commit/tag)
TRANSFORMERS_GIT_REF="${TRANSFORMERS_GIT_REF:-main}"

echo "=============================================="
echo " MetalGPT Install v3 (two venvs, reproducible)"
echo "=============================================="
echo "Repo: $REPO_DIR"
echo "App:  $APP_DIR"
echo "Model dir: $MODEL_DIR"
echo "Torch index: $TORCH_INDEX_URL"
echo "vLLM ref: $VLLM_GIT_REF"
echo "transformers ref: $TRANSFORMERS_GIT_REF"
echo

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash install.sh"
  exit 1
fi

# ---------------------------
# Helpers
# ---------------------------

log() { echo -e "\n\033[1m$*\033[0m"; }

pip_safe() {
  # pip command wrapper
  "$@" --no-cache-dir
}

extract_torch_requirement() {
  # Extract something like "torch==2.5.1" or "torch>=2.6.0"
  # from `pip show vllm` Requires: line.
  local reqs="$1"
  # isolate torch constraint: torch==X or torch>=X etc.
  echo "$reqs" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^torch([<>=!~]=|$)' | head -n1 || true
}

extract_xformers_requirement() {
  local reqs="$1"
  echo "$reqs" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^xformers([<>=!~]=|$)' | head -n1 || true
}

python_in_venv() {
  local venv="$1"; shift
  "$venv/bin/python" "$@"
}

pip_in_venv() {
  local venv="$1"; shift
  "$venv/bin/pip" "$@"
}

# ---------------------------
# 1) OS deps
# ---------------------------

log "[1/13] Install OS packages..."
apt-get update -y
apt-get install -y \
  nginx curl rsync git \
  python3 python3-venv python3-pip \
  ca-certificates \
  jq

# docker for redis
if [[ "$ENABLE_REDIS" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker || true
  fi
fi

# ---------------------------
# 2) Sync repo to /opt/metalgpt
# ---------------------------

log "[2/13] Sync repo -> ${APP_DIR}..."
mkdir -p "$APP_DIR"
rsync -a --delete "$REPO_DIR"/ "$APP_DIR"/

# ---------------------------
# 3) HF cache
# ---------------------------

log "[3/13] Prepare HuggingFace cache..."
mkdir -p "$HF_CACHE"
chmod -R 777 "$HF_CACHE"
echo "[OK] HF cache: $HF_CACHE"

# ---------------------------
# 4) Ensure backend .env
# ---------------------------

log "[4/13] Ensure backend/.env exists..."
if [[ ! -f "$APP_DIR/backend/.env" ]]; then
  if [[ -f "$APP_DIR/backend/.env.example" ]]; then
    cp "$APP_DIR/backend/.env.example" "$APP_DIR/backend/.env"
  else
    cat > "$APP_DIR/backend/.env" <<'ENV'
APP_API_KEY=change-me
VLLM_BASE=http://127.0.0.1:8000/v1
VLLM_KEY=local-token
MODEL=nn-tech/MetalGPT-1
REDIS_URL=redis://127.0.0.1:6379/0
REDIS_PREFIX=metalgpt:
SESSION_TTL_SECONDS=604800
SYSTEM_PROMPT=Ты эксперт по металлургии. Отвечай структурировано.
MAX_CONTEXT_TOKENS=16384
RESERVE_FOR_GENERATION=1200
MIN_KEEP_MESSAGES=6
CORS_ORIGIN=*
ENV
  fi
  echo "[OK] Created backend/.env"
else
  echo "[OK] backend/.env exists"
fi

# ---------------------------
# 5) backend-venv
# ---------------------------

log "[5/13] Create backend venv..."
if [[ "$REBUILD_VENVS" == "1" ]]; then
  rm -rf "$BACKEND_VENV"
fi
if [[ ! -x "$BACKEND_VENV/bin/python" ]]; then
  python3 -m venv "$BACKEND_VENV"
  pip_in_venv "$BACKEND_VENV" install -U pip wheel setuptools
fi

log "[6/13] Install backend requirements..."
pip_in_venv "$BACKEND_VENV" install -r "$APP_DIR/backend/requirements.txt"

# Optional sanity check to ensure backend doesn't pull torch/transformers accidentally
if grep -Eiq "torch|transformers|vllm|xformers" "$APP_DIR/backend/requirements.txt"; then
  echo "[WARN] backend/requirements.txt contains torch/transformers/vllm/xformers."
  echo "       This is not recommended. Consider removing them to keep backend-venv light."
fi

# ---------------------------
# 6) vllm-venv (reproducible)
# ---------------------------

log "[7/13] Create vLLM venv..."
if [[ "$REBUILD_VENVS" == "1" ]]; then
  rm -rf "$VLLM_VENV"
fi
if [[ ! -x "$VLLM_VENV/bin/python" ]]; then
  python3 -m venv "$VLLM_VENV"
  pip_in_venv "$VLLM_VENV" install -U pip wheel setuptools
fi

log "[8/13] Pin numpy (<2.0) and install core deps..."
pip_in_venv "$VLLM_VENV" install -U "numpy==1.26.4"

# ---------------------------
# 7) Install vLLM from GitHub WITHOUT torch first
#    We'll let vLLM declare required torch version,
#    then install torch accordingly.
# ---------------------------

log "[9/13] Install vLLM from GitHub (ref=${VLLM_GIT_REF})..."
# Uninstall any existing vllm to avoid mixed state
pip_in_venv "$VLLM_VENV" uninstall -y vllm >/dev/null 2>&1 || true

# Install vllm from git; allow pip to install deps (except torch)
# We'll install torch after we read requirements.
pip_in_venv "$VLLM_VENV" install -U "git+https://github.com/vllm-project/vllm.git@${VLLM_GIT_REF}"

# ---------------------------
# 8) Parse vLLM requirements to pick torch
# ---------------------------

log "[10/13] Auto-detect torch requirement from vLLM metadata..."
REQS_LINE="$(pip_in_venv "$VLLM_VENV" show vllm | awk -F': ' '/^Requires:/{print $2}')"
echo "[INFO] vLLM Requires: ${REQS_LINE}"

TORCH_REQ="$(extract_torch_requirement "$REQS_LINE")"
XFORMERS_REQ="$(extract_xformers_requirement "$REQS_LINE")"

if [[ -z "$TORCH_REQ" ]]; then
  echo "[WARN] Could not detect torch requirement from vLLM. Falling back to torch==2.5.1"
  TORCH_REQ="torch==2.5.1"
fi

echo "[OK] Detected torch requirement: ${TORCH_REQ}"
if [[ -n "$XFORMERS_REQ" ]]; then
  echo "[OK] Detected xformers requirement: ${XFORMERS_REQ}"
fi

log "[10b/13] Install torch via official wheels (${TORCH_INDEX_URL})..."
pip_in_venv "$VLLM_VENV" install -U ${TORCH_REQ} --index-url "$TORCH_INDEX_URL"

# torchvision: not strictly required for vLLM, but often useful; install a compatible version.
# We try to infer torchvision version for common torch versions, else skip gracefully.
TORCH_VER="$(python_in_venv "$VLLM_VENV" - <<'PY'
import torch
print(torch.__version__.split('+')[0])
PY
)"

case "$TORCH_VER" in
  2.5.1) TV_REQ="torchvision==0.20.1" ;;
  2.6.*) TV_REQ="torchvision==0.21.0" ;;
  2.7.*) TV_REQ="torchvision==0.22.0" ;;
  2.8.*) TV_REQ="torchvision==0.23.0" ;;
  2.9.*) TV_REQ="torchvision==0.24.0" ;;
  *)     TV_REQ="" ;;
esac

if [[ -n "$TV_REQ" ]]; then
  log "[10c/13] Install torchvision (${TV_REQ})..."
  pip_in_venv "$VLLM_VENV" install -U ${TV_REQ} --index-url "$TORCH_INDEX_URL" || true
else
  echo "[INFO] Skipping torchvision (unknown mapping for torch ${TORCH_VER})"
fi

# If vLLM declares xformers requirement, install it (best effort).
if [[ -n "$XFORMERS_REQ" ]]; then
  log "[10d/13] Install xformers (${XFORMERS_REQ})..."
  pip_in_venv "$VLLM_VENV" install -U ${XFORMERS_REQ} || true
fi

# ---------------------------
# 9) Install Transformers from GitHub (Qwen3)
# ---------------------------

log "[11/13] Install transformers+accelerate from GitHub (ref=${TRANSFORMERS_GIT_REF})..."
pip_in_venv "$VLLM_VENV" install -U \
  "git+https://github.com/huggingface/transformers.git@${TRANSFORMERS_GIT_REF}" \
  "git+https://github.com/huggingface/accelerate.git@${TRANSFORMERS_GIT_REF}"

pip_in_venv "$VLLM_VENV" install -U tokenizers huggingface-hub safetensors sentencepiece

log "[11b/13] Environment verify (versions + pip check)..."
python_in_venv "$VLLM_VENV" - <<'PY'
import numpy as np, torch, transformers
import vllm
print("numpy:", np.__version__)
print("torch:", torch.__version__)
print("transformers:", transformers.__version__)
print("vllm:", vllm.__version__)
PY

echo "[INFO] pip check:"
pip_in_venv "$VLLM_VENV" check || true

# ---------------------------
# 10) Verify model config loads
# ---------------------------

log "[12/13] Verify model config (qwen3) loads..."
if [[ -d "$MODEL_DIR" ]]; then
  python_in_venv "$VLLM_VENV" - <<PY
from transformers import AutoConfig
cfg = AutoConfig.from_pretrained("$MODEL_DIR", trust_remote_code=True)
print("OK model_type:", cfg.model_type)
print("architectures:", getattr(cfg, "architectures", None))
PY
else
  echo "[WARN] Model dir not found: $MODEL_DIR"
  echo "You must download model into /opt/models/MetalGPT-1 before starting vLLM."
fi

# ---------------------------
# 11) Redis (optional)
# ---------------------------

log "[12b/13] Start Redis (optional)..."
if [[ "$ENABLE_REDIS" == "1" && -f "$APP_DIR/deploy/docker-compose.redis.yml" ]]; then
  (cd "$APP_DIR/deploy" && docker compose -f docker-compose.redis.yml up -d)
  echo "[OK] Redis started"
else
  echo "[INFO] Redis skipped (ENABLE_REDIS=$ENABLE_REDIS)"
fi

# ---------------------------
# 12) systemd services
# ---------------------------

log "[13/13] Install systemd units..."

cat > /etc/systemd/system/metalgpt-web.service <<SVC
[Unit]
Description=MetalGPT Web Backend (FastAPI/Uvicorn)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=${BACKEND_VENV}/bin/uvicorn main:app --host 127.0.0.1 --port 9000
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/metalgpt-vllm.service <<SVC
[Unit]
Description=MetalGPT vLLM Service (GitHub vLLM + Auto Torch)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="HF_HOME=${HF_CACHE}"
Environment="HUGGINGFACE_HUB_CACHE=${HF_CACHE}"
Environment="TRANSFORMERS_CACHE=${HF_CACHE}"

ExecStart=${VLLM_VENV}/bin/python -m vllm.entrypoints.openai.api_server \\
  --model ${MODEL_DIR} \\
  --host 127.0.0.1 --port 8000 \\
  --dtype auto \\
  --max-model-len 16384 \\
  --gpu-memory-utilization 0.90 \\
  --enable-chunked-prefill \\
  --max-num-seqs 24 \\
  --max-num-batched-tokens 12288 \\
  --trust-remote-code \\
  --api-key local-token

Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now metalgpt-web metalgpt-vllm
systemctl restart metalgpt-web metalgpt-vllm

echo
echo "==== STATUS ===="
systemctl status metalgpt-web --no-pager || true
echo
systemctl status metalgpt-vllm --no-pager || true

echo
echo "==== HEALTHCHECKS ===="
echo "--- backend (9000) ---"
curl -I --max-time 3 http://127.0.0.1:9000/ || true
echo "--- vLLM (8000) ---"
curl -s --max-time 5 http://127.0.0.1:8000/v1/models | head -c 600 || true
echo

echo "=============================================="
echo "DONE ✅"
echo "Logs:"
echo "  journalctl -u metalgpt-web -n 200 --no-pager"
echo "  journalctl -u metalgpt-vllm -n 200 --no-pager"
echo
echo "Venvs:"
echo "  Backend: ${BACKEND_VENV}"
echo "  vLLM:    ${VLLM_VENV}"
echo
echo "Repro tips:"
echo "  - To rebuild venvs: REBUILD_VENVS=1 sudo bash install.sh"
echo "  - To keep venvs:    REBUILD_VENVS=0 sudo bash install.sh"
echo "  - To pin vLLM ref:  VLLM_GIT_REF=<commit> sudo bash install.sh"
echo "=============================================="
EOF

chmod +x install.sh
echo "✅ install.sh v3 generated. Run: sudo bash install.sh"

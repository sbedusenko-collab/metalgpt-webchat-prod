cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

# ============================================
# MetalGPT Install v3 (reproducible, 2 venvs)
# - backend-venv (FastAPI)
# - vllm-venv (vLLM nightly wheel + auto torch)
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
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"

# Reproducibility:
REBUILD_VENVS="${REBUILD_VENVS:-1}"   # 1 = recreate venvs each run
VLLM_VERSION="${VLLM_VERSION:-}"      # optional pin: e.g. 0.11.0.dev2025xxxx
TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-}" # optional pin

# vLLM nightly wheels
VLLM_NIGHTLY_INDEX="https://wheels.vllm.ai/nightly"

log() { echo -e "\n\033[1m$*\033[0m"; }

pip_in_venv() { "$1/bin/pip" "${@:2}"; }
python_in_venv() { "$1/bin/python" "${@:2}"; }

extract_torch_requirement() {
  local reqs="$1"
  echo "$reqs" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^torch([<>=!~]=|$)' | head -n1 || true
}

echo "=============================================="
echo " MetalGPT Install v3 (two venvs, vLLM nightly)"
echo "=============================================="
echo "Repo: $REPO_DIR"
echo "App:  $APP_DIR"
echo "Model dir: $MODEL_DIR"
echo "Torch index: $TORCH_INDEX_URL"
echo "vLLM nightly index: $VLLM_NIGHTLY_INDEX"
echo "vLLM pin version: ${VLLM_VERSION:-<latest nightly>}"
echo

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash install.sh"
  exit 1
fi

log "[1/12] Install OS packages..."
apt-get update -y
apt-get install -y nginx curl rsync git python3 python3-venv python3-pip ca-certificates jq

if [[ "$ENABLE_REDIS" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker || true
  fi
fi

log "[2/12] Sync repo -> ${APP_DIR}..."
mkdir -p "$APP_DIR"
rsync -a --delete "$REPO_DIR"/ "$APP_DIR"/

log "[3/12] Prepare HF cache..."
mkdir -p "$HF_CACHE"
chmod -R 777 "$HF_CACHE"
echo "[OK] HF cache: $HF_CACHE"

log "[4/12] Ensure backend/.env exists..."
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
fi

log "[5/12] Create backend-venv..."
if [[ "$REBUILD_VENVS" == "1" ]]; then rm -rf "$BACKEND_VENV"; fi
if [[ ! -x "$BACKEND_VENV/bin/python" ]]; then
  python3 -m venv "$BACKEND_VENV"
  pip_in_venv "$BACKEND_VENV" install -U pip wheel setuptools
fi
pip_in_venv "$BACKEND_VENV" install -r "$APP_DIR/backend/requirements.txt"

log "[6/12] Create vllm-venv..."
if [[ "$REBUILD_VENVS" == "1" ]]; then rm -rf "$VLLM_VENV"; fi
if [[ ! -x "$VLLM_VENV/bin/python" ]]; then
  python3 -m venv "$VLLM_VENV"
  pip_in_venv "$VLLM_VENV" install -U pip wheel setuptools
fi

log "[7/12] Install vLLM from nightly wheels (no compilation)..."
pip_in_venv "$VLLM_VENV" uninstall -y vllm >/dev/null 2>&1 || true

# Pin numpy to avoid numpy2 incompatibility
pip_in_venv "$VLLM_VENV" install -U "numpy==1.26.4"

if [[ -n "$VLLM_VERSION" ]]; then
  pip_in_venv "$VLLM_VENV" install -U --pre \
    --extra-index-url "$VLLM_NIGHTLY_INDEX" \
    "vllm==${VLLM_VERSION}"
else
  pip_in_venv "$VLLM_VENV" install -U --pre \
    --extra-index-url "$VLLM_NIGHTLY_INDEX" \
    vllm
fi

log "[8/12] Auto-detect torch requirement (best-effort) + install torch wheels..."
REQS_LINE="$(pip_in_venv "$VLLM_VENV" show vllm | awk -F': ' '/^Requires:/{print $2}')"
echo "[INFO] vLLM Requires: $REQS_LINE"
TORCH_REQ="$(extract_torch_requirement "$REQS_LINE")"

if [[ -z "$TORCH_REQ" ]]; then
  echo "[WARN] torch requirement not found, installing torch==2.5.1"
  TORCH_REQ="torch==2.5.1"
fi

echo "[OK] Installing: $TORCH_REQ"
pip_in_venv "$VLLM_VENV" install -U $TORCH_REQ --index-url "$TORCH_INDEX_URL" || true

# Optional torchvision for sanity
pip_in_venv "$VLLM_VENV" install -U torchvision --index-url "$TORCH_INDEX_URL" || true

log "[9/12] Install transformers (for qwen3) ..."
if [[ -n "$TRANSFORMERS_VERSION" ]]; then
  pip_in_venv "$VLLM_VENV" install -U "transformers==${TRANSFORMERS_VERSION}"
else
  pip_in_venv "$VLLM_VENV" install -U transformers accelerate tokenizers huggingface-hub safetensors sentencepiece
fi

log "[10/12] Version check..."
python_in_venv "$VLLM_VENV" - <<'PY'
import vllm, torch, transformers
print("vllm:", vllm.__version__)
print("torch:", torch.__version__)
print("transformers:", transformers.__version__)
PY

log "[11/12] Install systemd units..."
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
Description=MetalGPT vLLM Service (Nightly wheels)
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

log "[12/12] Healthchecks..."
curl -I --max-time 3 http://127.0.0.1:9000/ || true
curl -s --max-time 5 http://127.0.0.1:8000/v1/models | head -c 600 || true

echo
echo "=============================================="
echo "DONE ✅"
echo "Logs:"
echo "  journalctl -u metalgpt-web -n 200 --no-pager"
echo "  journalctl -u metalgpt-vllm -n 200 --no-pager"
echo "=============================================="
EOF

chmod +x install.sh
echo "✅ install.sh v3 updated (nightly wheels). Run: sudo bash install.sh"

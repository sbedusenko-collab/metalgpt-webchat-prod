cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -o pipefail

# ===============================
# MetalGPT Webchat Install v2
# Two venvs: backend-venv + vllm-venv
# ===============================

APP_DIR="/opt/metalgpt"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKEND_VENV="${APP_DIR}/backend-venv"
VLLM_VENV="${APP_DIR}/vllm-venv"

MODEL_DIR="/opt/models/MetalGPT-1"
HF_CACHE="${APP_DIR}/hf_cache"

# torch wheels (default: cu121)
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"

DOMAIN="${DOMAIN:-metal-gpt.ru}"
ENABLE_NGINX="${ENABLE_NGINX:-1}"
ENABLE_REDIS="${ENABLE_REDIS:-1}"

echo "========================================"
echo " MetalGPT Install v2 (two venvs) ✅"
echo "========================================"
echo "Repo: $REPO_DIR"
echo "App:  $APP_DIR"
echo "Torch index: $TORCH_INDEX_URL"
echo

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash install.sh"
  exit 1
fi

echo "[1/12] Install OS packages..."
apt-get update -y
apt-get install -y \
  nginx curl rsync git \
  python3 python3-venv python3-pip \
  ca-certificates

# docker for redis
if [[ "$ENABLE_REDIS" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker || true
  fi
fi

echo
echo "[2/12] Sync repo -> /opt/metalgpt..."
mkdir -p "$APP_DIR"
rsync -a --delete "$REPO_DIR"/ "$APP_DIR"/

echo
echo "[3/12] Prepare HF cache..."
mkdir -p "$HF_CACHE"
chmod -R 777 "$HF_CACHE"
echo "[OK] HF cache: $HF_CACHE"

echo
echo "[4/12] Ensure backend .env exists..."
if [[ ! -f "$APP_DIR/backend/.env" ]]; then
  if [[ -f "$APP_DIR/backend/.env.example" ]]; then
    cp "$APP_DIR/backend/.env.example" "$APP_DIR/backend/.env"
  else
    cat > "$APP_DIR/backend/.env" <<'ENV'
APP_API_KEY=
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
  echo "[OK] Found backend/.env"
fi

echo
echo "[5/12] Create backend venv + install deps..."
rm -rf "$BACKEND_VENV"
python3 -m venv "$BACKEND_VENV"
"$BACKEND_VENV/bin/pip" install -U pip wheel setuptools

# Install backend deps
"$BACKEND_VENV/bin/pip" install -r "$APP_DIR/backend/requirements.txt"

echo
echo "[6/12] Create vLLM venv + install pinned compatible deps..."
rm -rf "$VLLM_VENV"
python3 -m venv "$VLLM_VENV"
"$VLLM_VENV/bin/pip" install -U pip wheel setuptools

# vLLM strict deps
"$VLLM_VENV/bin/pip" install -U --no-cache-dir "numpy==1.26.4"

"$VLLM_VENV/bin/pip" install -U --no-cache-dir \
  torch==2.5.1 torchvision==0.20.1 --index-url "$TORCH_INDEX_URL"

"$VLLM_VENV/bin/pip" install -U --no-cache-dir "vllm==0.7.0"

# Transformers GitHub for qwen3
"$VLLM_VENV/bin/pip" install -U --no-cache-dir \
  git+https://github.com/huggingface/transformers.git \
  git+https://github.com/huggingface/accelerate.git

"$VLLM_VENV/bin/pip" install -U --no-cache-dir \
  tokenizers huggingface-hub safetensors sentencepiece

echo
echo "[7/12] Verify transformers can read qwen3 config..."
if [[ -d "$MODEL_DIR" ]]; then
  "$VLLM_VENV/bin/python" - <<PY
from transformers import AutoConfig
cfg = AutoConfig.from_pretrained("$MODEL_DIR", trust_remote_code=True)
print("OK model_type:", cfg.model_type)
PY
else
  echo "[WARN] Model dir not found: $MODEL_DIR"
  echo "You can download model later into /opt/models/MetalGPT-1"
fi

echo
echo "[8/12] Start Redis (optional)..."
if [[ "$ENABLE_REDIS" == "1" && -f "$APP_DIR/deploy/docker-compose.redis.yml" ]]; then
  (cd "$APP_DIR/deploy" && docker compose -f docker-compose.redis.yml up -d)
  echo "[OK] Redis started"
else
  echo "[INFO] Redis skipped (ENABLE_REDIS=$ENABLE_REDIS)"
fi

echo
echo "[9/12] Install systemd units..."

# metalgpt-web (backend)
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

# metalgpt-vllm
cat > /etc/systemd/system/metalgpt-vllm.service <<SVC
[Unit]
Description=MetalGPT vLLM Service
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
echo "[10/12] Nginx config (optional)..."
if [[ "$ENABLE_NGINX" == "1" && -f "$APP_DIR/deploy/nginx/metalgpt.conf" ]]; then
  cp "$APP_DIR/deploy/nginx/metalgpt.conf" /etc/nginx/sites-available/metalgpt.conf
  ln -sf /etc/nginx/sites-available/metalgpt.conf /etc/nginx/sites-enabled/metalgpt.conf
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl restart nginx
  echo "[OK] Nginx enabled"
else
  echo "[INFO] Nginx skipped (ENABLE_NGINX=$ENABLE_NGINX)"
fi

echo
echo "[11/12] Health checks..."
echo "--- backend (9000) ---"
curl -I --max-time 3 http://127.0.0.1:9000/ || true
echo "--- nginx (80) ---"
curl -I --max-time 3 http://127.0.0.1/ || true
echo "--- vLLM (8000) ---"
curl -s --max-time 3 http://127.0.0.1:8000/v1/models | head -c 400 || true
echo

echo
echo "[12/12] Done ✅"
echo "Services:"
echo "  systemctl status metalgpt-web --no-pager"
echo "  systemctl status metalgpt-vllm --no-pager"
echo
echo "Logs:"
echo "  journalctl -u metalgpt-web -n 200 --no-pager"
echo "  journalctl -u metalgpt-vllm -n 200 --no-pager"
echo
echo "Venvs:"
echo "  Backend: $BACKEND_VENV"
echo "  vLLM:    $VLLM_VENV"
EOF
chmod +x install.sh
echo "✅ install.sh updated (v2). Run: sudo bash install.sh"

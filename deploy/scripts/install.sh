cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/metalgpt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# We assume install.sh is inside repo (maybe deploy/scripts or root)
# Try detect repo root by going up until we find backend/main.py or deploy/
REPO_CANDIDATES=(
  "$SCRIPT_DIR"
  "$SCRIPT_DIR/.."
  "$SCRIPT_DIR/../.."
  "$SCRIPT_DIR/../../.."
)

REPO_DIR=""
for d in "${REPO_CANDIDATES[@]}"; do
  if [[ -d "$d" ]]; then
    if [[ -d "$d/backend" ]] || [[ -d "$d/frontend" ]] || [[ -d "$d/deploy" ]]; then
      REPO_DIR="$(cd "$d" && pwd)"
      break
    fi
  fi
done

if [[ -z "$REPO_DIR" ]]; then
  echo "[ERROR] Cannot detect repo root from $SCRIPT_DIR"
  exit 1
fi

BACKEND_VENV="${APP_DIR}/backend-venv"
VLLM_VENV="${APP_DIR}/vllm-venv"

MODEL_DIR="${MODEL_DIR:-/opt/models/MetalGPT-1}"
HF_CACHE="${APP_DIR}/hf_cache"

ENABLE_REDIS="${ENABLE_REDIS:-1}"
REBUILD_VENVS="${REBUILD_VENVS:-1}"

TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"
VLLM_NIGHTLY_INDEX="https://wheels.vllm.ai/nightly"

echo "=============================================="
echo " MetalGPT Install v3.2 (AUTO-DETECT)"
echo "=============================================="
echo "SCRIPT_DIR: $SCRIPT_DIR"
echo "REPO_DIR:   $REPO_DIR"
echo "APP_DIR:    $APP_DIR"
echo "MODEL_DIR:  $MODEL_DIR"
echo "=============================================="
echo

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo bash install.sh"
  exit 1
fi

echo "[1/12] Install OS deps..."
apt-get update -y
apt-get install -y nginx curl rsync git python3 python3-venv python3-pip ca-certificates jq

if [[ "$ENABLE_REDIS" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker || true
  fi
fi

echo
echo "[2/12] Sync repo -> ${APP_DIR}"
mkdir -p "$APP_DIR"
rsync -a --delete "$REPO_DIR"/ "$APP_DIR"/

echo
echo "[3/12] Detect backend directory inside /opt/metalgpt..."
BACKEND_DIR=""

# Try known paths first
KNOWN_BACKEND_PATHS=(
  "$APP_DIR/backend"
  "$APP_DIR/app/backend"
  "$APP_DIR/server"
  "$APP_DIR/src/backend"
)

for d in "${KNOWN_BACKEND_PATHS[@]}"; do
  if [[ -f "$d/requirements.txt" ]]; then
    BACKEND_DIR="$d"
    break
  fi
done

# Fallback: search requirements.txt that contains fastapi
if [[ -z "$BACKEND_DIR" ]]; then
  CAND_REQS=$(find "$APP_DIR" -maxdepth 4 -type f -name requirements.txt | head -n 30 || true)
  while read -r f; do
    if grep -qiE 'fastapi|uvicorn' "$f"; then
      BACKEND_DIR="$(dirname "$f")"
      break
    fi
  done <<< "$CAND_REQS"
fi

if [[ -z "$BACKEND_DIR" ]]; then
  echo "[ERROR] Could not locate backend requirements.txt in $APP_DIR"
  echo "Try: find $APP_DIR -maxdepth 5 -name requirements.txt"
  exit 1
fi

echo "[OK] Backend dir detected: $BACKEND_DIR"

REQ_FILE="$BACKEND_DIR/requirements.txt"
MAIN_FILE="$BACKEND_DIR/main.py"

if [[ ! -f "$REQ_FILE" ]]; then
  echo "[ERROR] requirements.txt not found at $REQ_FILE"
  exit 1
fi

if [[ ! -f "$MAIN_FILE" ]]; then
  echo "[WARN] main.py not found at $MAIN_FILE"
  echo "We will still proceed, but systemd unit expects main:app"
fi

echo
echo "[4/12] Prepare HF cache"
mkdir -p "$HF_CACHE"
chmod -R 777 "$HF_CACHE"

echo
echo "[5/12] Ensure backend/.env exists"
mkdir -p "$BACKEND_DIR"
if [[ ! -f "$BACKEND_DIR/.env" ]]; then
  if [[ -f "$BACKEND_DIR/.env.example" ]]; then
    cp "$BACKEND_DIR/.env.example" "$BACKEND_DIR/.env"
  else
    cat > "$BACKEND_DIR/.env" <<'ENV'
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

echo
echo "[6/12] Create backend venv"
if [[ "$REBUILD_VENVS" == "1" ]]; then rm -rf "$BACKEND_VENV"; fi
if [[ ! -x "$BACKEND_VENV/bin/python" ]]; then
  python3 -m venv "$BACKEND_VENV"
  "$BACKEND_VENV/bin/pip" install -U pip wheel setuptools
fi
"$BACKEND_VENV/bin/pip" install -r "$REQ_FILE"

echo
echo "[7/12] Create vLLM venv"
if [[ "$REBUILD_VENVS" == "1" ]]; then rm -rf "$VLLM_VENV"; fi
if [[ ! -x "$VLLM_VENV/bin/python" ]]; then
  python3 -m venv "$VLLM_VENV"
  "$VLLM_VENV/bin/pip" install -U pip wheel setuptools
fi

echo
echo "[8/12] Install vLLM nightly wheels"
"$VLLM_VENV/bin/pip" uninstall -y vllm >/dev/null 2>&1 || true
"$VLLM_VENV/bin/pip" install -U "numpy==1.26.4"
"$VLLM_VENV/bin/pip" install -U --pre --extra-index-url "$VLLM_NIGHTLY_INDEX" vllm

echo
echo "[9/12] Install torch"
"$VLLM_VENV/bin/pip" install -U torch torchvision --index-url "$TORCH_INDEX_URL" || true

echo
echo "[10/12] Install transformers"
"$VLLM_VENV/bin/pip" install -U transformers accelerate tokenizers huggingface-hub safetensors sentencepiece

echo
echo "[11/12] Install systemd units"
cat > /etc/systemd/system/metalgpt-web.service <<SVC
[Unit]
Description=MetalGPT Web Backend (FastAPI/Uvicorn)
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=${BACKEND_DIR}
EnvironmentFile=${BACKEND_DIR}/.env
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

echo
echo "[12/12] Health checks"
curl -I --max-time 3 http://127.0.0.1:9000/ || true
curl -s --max-time 5 http://127.0.0.1:8000/v1/models | head -c 500 || true

echo
echo "=============================================="
echo "DONE ✅"
echo "Backend dir: $BACKEND_DIR"
echo "Logs:"
echo "  journalctl -u metalgpt-web -n 200 --no-pager"
echo "  journalctl -u metalgpt-vllm -n 200 --no-pager"
echo "=============================================="
EOF

chmod +x install.sh

{\rtf1\ansi\ansicpg1251\cocoartf2822
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\froman\fcharset0 Times-Roman;}
{\colortbl;\red255\green255\blue255;\red0\green0\blue0;}
{\*\expandedcolortbl;;\cssrgb\c0\c0\c0;}
\paperw11900\paperh16840\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\deftab720
\pard\pardeftab720\partightenfactor0

\f0\fs24 \cf0 \expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 import os\
import json\
import hashlib\
from typing import List, Optional\
\
import httpx\
import redis.asyncio as redis\
from dotenv import load_dotenv\
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException\
from fastapi.middleware.cors import CORSMiddleware\
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse\
from fastapi.staticfiles import StaticFiles\
\
from transformers import AutoTokenizer\
\
load_dotenv()\
\
# ===== vLLM OpenAI-compatible server =====\
VLLM_BASE = os.getenv("VLLM_BASE", "http://127.0.0.1:8000/v1").rstrip("/")\
VLLM_KEY = os.getenv("VLLM_KEY", "local-token")\
MODEL = os.getenv("MODEL", "nn-tech/MetalGPT-1")\
\
# ===== Auth =====\
API_KEY = os.getenv("APP_API_KEY", "")  # empty -> auth disabled\
\
# ===== Redis =====\
REDIS_URL = os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0")\
REDIS_PREFIX = os.getenv("REDIS_PREFIX", "metalgpt:")\
SESSION_TTL_SECONDS = int(os.getenv("SESSION_TTL_SECONDS", str(60 * 60 * 24 * 7)))  # default 7d\
\
# ===== Chat settings =====\
SYSTEM_PROMPT = os.getenv(\
    "SYSTEM_PROMPT",\
    "\uc0\u1058 \u1099  \u1101 \u1082 \u1089 \u1087 \u1077 \u1088 \u1090  \u1087 \u1086  \u1084 \u1077 \u1090 \u1072 \u1083 \u1083 \u1091 \u1088 \u1075 \u1080 \u1080 . \u1054 \u1090 \u1074 \u1077 \u1095 \u1072 \u1081  \u1089 \u1090 \u1088 \u1091 \u1082 \u1090 \u1091 \u1088 \u1080 \u1088 \u1086 \u1074 \u1072 \u1085 \u1086 , \u1091 \u1090 \u1086 \u1095 \u1085 \u1103 \u1081  \u1076 \u1086 \u1087 \u1091 \u1097 \u1077 \u1085 \u1080 \u1103 , \u1080 \u1079 \u1073 \u1077 \u1075 \u1072 \u1081  \u1074 \u1099 \u1076 \u1091 \u1084 \u1072 \u1085 \u1085 \u1099 \u1093  \u1092 \u1072 \u1082 \u1090 \u1086 \u1074 ."\
)\
\
# Context budgeting: keep history within MAX_CONTEXT_TOKENS - RESERVE_FOR_GENERATION\
MAX_CONTEXT_TOKENS = int(os.getenv("MAX_CONTEXT_TOKENS", "16384"))\
RESERVE_FOR_GENERATION = int(os.getenv("RESERVE_FOR_GENERATION", "1200"))\
MIN_KEEP_MESSAGES = int(os.getenv("MIN_KEEP_MESSAGES", "6"))  # system + a few turns\
\
# ===== App =====\
app = FastAPI(title="MetalGPT Web Chat (Prod++)")\
\
app.add_middleware(\
    CORSMiddleware,\
    allow_origins=[os.getenv("CORS_ORIGIN", "*")],\
    allow_credentials=True,\
    allow_methods=["*"],\
    allow_headers=["*"],\
)\
\
FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")\
app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")\
\
r: Optional[redis.Redis] = None\
tokenizer: Optional[AutoTokenizer] = None\
\
\
@app.on_event("startup")\
async def _startup():\
    global r, tokenizer\
    r = redis.from_url(REDIS_URL, decode_responses=True)\
    # Tokenizer is light; model weights are NOT loaded here.\
    tokenizer = AutoTokenizer.from_pretrained(MODEL, use_fast=True)\
\
\
@app.on_event("shutdown")\
async def _shutdown():\
    global r\
    if r is not None:\
        await r.close()\
\
\
def _auth_ok_ws(ws: WebSocket) -> bool:\
    if not API_KEY:\
        return True\
    # Browser WS can't easily set custom headers -> allow query param\
    q = ws.query_params.get("api_key")\
    h = ws.headers.get("x-api-key")\
    return (q == API_KEY) or (h == API_KEY)\
\
\
def _auth_ok_http(req: Request) -> bool:\
    if not API_KEY:\
        return True\
    h = req.headers.get("x-api-key")\
    q = req.query_params.get("api_key")\
    return (h == API_KEY) or (q == API_KEY)\
\
\
@app.get("/", response_class=HTMLResponse)\
async def index(request: Request):\
    if not _auth_ok_http(request):\
        raise HTTPException(status_code=401, detail="Unauthorized")\
    return FileResponse(os.path.join(FRONTEND_DIR, "index.html"))\
\
\
def _redis_key(user_id: str) -> str:\
    # stable, safe key\
    h = hashlib.sha256(user_id.encode("utf-8")).hexdigest()\
    return f"\{REDIS_PREFIX\}user:\{h\}:chat"\
\
\
async def _load_user_history(user_id: str) -> List[dict]:\
    assert r is not None\
    key = _redis_key(user_id)\
    raw = await r.get(key)\
    if raw:\
        return json.loads(raw)\
\
    msgs = [\{"role": "system", "content": SYSTEM_PROMPT\}]\
    await r.set(key, json.dumps(msgs), ex=SESSION_TTL_SECONDS)\
    return msgs\
\
\
async def _save_user_history(user_id: str, msgs: List[dict]):\
    assert r is not None\
    key = _redis_key(user_id)\
    await r.set(key, json.dumps(msgs), ex=SESSION_TTL_SECONDS)\
\
\
async def _clear_user_history(user_id: str):\
    assert r is not None\
    key = _redis_key(user_id)\
    await r.delete(key)\
\
\
def _count_tokens(messages: List[dict]) -> int:\
    # Approximate token count: sum(tokenize(content)) for each message content.\
    # Good enough to trim history; exact chat-template token count is not required here.\
    assert tokenizer is not None\
    total = 0\
    for m in messages:\
        total += len(tokenizer.encode(m.get("content") or ""))\
    return total\
\
\
def _trim_to_budget(messages: List[dict]) -> List[dict]:\
    budget = max(1, MAX_CONTEXT_TOKENS - RESERVE_FOR_GENERATION)\
    msgs = messages[:]\
    while len(msgs) > MIN_KEEP_MESSAGES and _count_tokens(msgs) > budget:\
        msgs.pop(1)  # drop oldest after system\
    return msgs\
\
\
async def _stream_vllm_chat(messages: List[dict], temperature: float, max_tokens: int):\
    headers = \{"Authorization": f"Bearer \{VLLM_KEY\}"\}\
    payload = \{\
        "model": MODEL,\
        "messages": messages,\
        "temperature": temperature,\
        "max_tokens": max_tokens,\
        "stream": True,\
    \}\
\
    async with httpx.AsyncClient(timeout=None) as client:\
        async with client.stream(\
            "POST",\
            f"\{VLLM_BASE\}/chat/completions",\
            headers=headers,\
            json=payload,\
        ) as resp:\
            resp.raise_for_status()\
            async for line in resp.aiter_lines():\
                if not line or not line.startswith("data:"):\
                    continue\
                data = line[len("data:"):].strip()\
                if data == "[DONE]":\
                    break\
                chunk = json.loads(data)\
                delta = chunk["choices"][0]["delta"].get("content")\
                if delta:\
                    yield delta\
@app.post("/api/clear")\
async def clear_http(request: Request):\
    """\
    Optional HTTP clear endpoint:\
    POST /api/clear\
    Body: \{"user_id": "..."\}\
    Auth: X-API-Key or ?api_key=...\
    """\
    if not _auth_ok_http(request):\
        raise HTTPException(status_code=401, detail="Unauthorized")\
\
    body = await request.json()\
    user_id = (body.get("user_id") or "").strip()\
    if not user_id:\
        raise HTTPException(status_code=400, detail="user_id required")\
\
    await _clear_user_history(user_id)\
    return JSONResponse(\{"ok": True\})\
\
\
@app.websocket("/ws")\
async def ws_chat(ws: WebSocket):\
    """\
    WebSocket protocol:\
      - chat message:\
          \{"type":"chat","user_id":"...","text":"...","temperature":0.2,"max_tokens":800\}\
      - clear history:\
          \{"type":"clear","user_id":"..."\}\
    Auth (optional): ?api_key=... or header X-API-Key\
    """\
    await ws.accept()\
\
    if not _auth_ok_ws(ws):\
        await ws.send_text(json.dumps(\{"type": "error", "message": "Unauthorized"\}))\
        await ws.close(code=4401)\
        return\
\
    try:\
        while True:\
            req = json.loads(await ws.receive_text())\
\
            user_id = (req.get("user_id") or "").strip()\
            if not user_id:\
                await ws.send_text(json.dumps(\{"type": "error", "message": "user_id required"\}))\
                continue\
\
            msg_type = (req.get("type") or "chat").strip().lower()\
\
            if msg_type == "clear":\
                await _clear_user_history(user_id)\
                await ws.send_text(json.dumps(\{"type": "cleared"\}))\
                continue\
\
            if msg_type != "chat":\
                await ws.send_text(json.dumps(\{"type": "error", "message": f"Unknown type: \{msg_type\}"\}))\
                continue\
\
            text = (req.get("text") or "").strip()\
            temperature = float(req.get("temperature", 0.2))\
            max_tokens = int(req.get("max_tokens", 800))\
\
            if not text:\
                await ws.send_text(json.dumps(\{"type": "error", "message": "\uc0\u1055 \u1091 \u1089 \u1090 \u1086 \u1077  \u1089 \u1086 \u1086 \u1073 \u1097 \u1077 \u1085 \u1080 \u1077 ."\}))\
                continue\
\
            # Load + append + trim\
            msgs = await _load_user_history(user_id)\
            msgs.append(\{"role": "user", "content": text\})\
            msgs = _trim_to_budget(msgs)\
\
            assistant_accum = ""\
            try:\
                async for delta in _stream_vllm_chat(msgs, temperature=temperature, max_tokens=max_tokens):\
                    assistant_accum += delta\
                    await ws.send_text(json.dumps(\{"type": "token", "text": delta\}))\
            except httpx.HTTPError as e:\
                await ws.send_text(json.dumps(\{"type": "error", "message": f"\uc0\u1054 \u1096 \u1080 \u1073 \u1082 \u1072  \u1079 \u1072 \u1087 \u1088 \u1086 \u1089 \u1072  \u1082  vLLM: \{e\}"\}))\
                continue\
\
            # Save assistant message + trim again\
            msgs.append(\{"role": "assistant", "content": assistant_accum\})\
            msgs = _trim_to_budget(msgs)\
            await _save_user_history(user_id, msgs)\
\
            await ws.send_text(json.dumps(\{"type": "done"\}))\
\
    except WebSocketDisconnect:\
        return\
}
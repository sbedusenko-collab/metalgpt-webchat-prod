import os
import json
import hashlib
from typing import List, Optional, Annotated

import httpx
import redis.asyncio as redis
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException, Depends, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from transformers import AutoTokenizer

load_dotenv()

# ===== Конфигурация сервера vLLM (OpenAI-совместимый) =====
VLLM_BASE = os.getenv("VLLM_BASE", "http://127.0.0.1:8000/v1").rstrip("/")
VLLM_KEY = os.getenv("VLLM_KEY", "local-token")
MODEL = os.getenv("MODEL", "nn-tech/MetalGPT-1")

# ===== Аутентификация =====
API_KEY = os.getenv("APP_API_KEY", "")  # пустая строка отключает аутентификацию

# ===== Настройки Redis =====
REDIS_URL = os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0")
REDIS_PREFIX = os.getenv("REDIS_PREFIX", "metalgpt:")
SESSION_TTL_SECONDS = int(os.getenv("SESSION_TTL_SECONDS", str(60 * 60 * 24 * 7)))  # время жизни сессии (по умолчанию 7 дней)

# ===== Настройки чата =====
SYSTEM_PROMPT = os.getenv(
    "SYSTEM_PROMPT",
    "Ты эксперт по металлургии. Отвечай структурировано, уточняй допущения, избегай выдуманных фактов."
)

# Бюджетирование контекста: история обрезается, чтобы оставаться в пределах MAX_CONTEXT_TOKENS - RESERVE_FOR_GENERATION
MAX_CONTEXT_TOKENS = int(os.getenv("MAX_CONTEXT_TOKENS", "16384"))
RESERVE_FOR_GENERATION = int(os.getenv("RESERVE_FOR_GENERATION", "1200"))
MIN_KEEP_MESSAGES = int(os.getenv("MIN_KEEP_MESSAGES", "6"))  # системный промпт + несколько последних сообщений

# ===== App =====
app = FastAPI(title="MetalGPT Web Chat (Prod++)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[os.getenv("CORS_ORIGIN", "*")],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")
app.mount("/static", StaticFiles(directory=os.path.join(FRONTEND_DIR, "static")), name="static")

r: Optional[redis.Redis] = None
tokenizer: Optional[AutoTokenizer] = None


@app.on_event("startup")
async def _startup():
    """Инициализация ресурсов при старте приложения."""
    global r, tokenizer
    r = redis.from_url(REDIS_URL, decode_responses=True)
    # Загружается только токенизатор, а не веса модели.
    tokenizer = AutoTokenizer.from_pretrained(MODEL, use_fast=True)


@app.on_event("shutdown")
async def _shutdown():
    """Освобождение ресурсов при остановке приложения."""
    global r
    if r is not None:
        await r.close()

# ===== Зависимости и аутентификация =====

def auth_dependency(
    request: Request,
    api_key: Annotated[Optional[str], Query()] = None
):
    """Зависимость для проверки API-ключа из заголовка или query-параметра."""
    if not API_KEY: # Аутентификация отключена
        return
    header_api_key = request.headers.get("x-api-key")
    if not (api_key == API_KEY or header_api_key == API_KEY):
        raise HTTPException(status_code=401, detail="Unauthorized")

@app.get("/", response_class=HTMLResponse)
async def index(_: Annotated[None, Depends(auth_dependency)]):
    """Отдает главную HTML-страницу фронтенда."""
    return FileResponse(os.path.join(FRONTEND_DIR, "index.html"))


def _redis_key(user_id: str) -> str:
    # stable, safe key
    h = hashlib.sha256(user_id.encode("utf-8")).hexdigest()
    return f"{REDIS_PREFIX}user:{h}:chat"


async def _load_user_history(user_id: str) -> List[dict]:
    """Загружает историю чата пользователя из Redis или создает новую."""
    assert r is not None
    key = _redis_key(user_id)
    raw = await r.get(key)
    if raw:
        return json.loads(raw)

    msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
    await r.set(key, json.dumps(msgs), ex=SESSION_TTL_SECONDS)
    return msgs


async def _save_user_history(user_id: str, msgs: List[dict]):
    """Сохраняет историю чата пользователя в Redis."""
    assert r is not None
    key = _redis_key(user_id)
    await r.set(key, json.dumps(msgs), ex=SESSION_TTL_SECONDS)


async def _clear_user_history(user_id: str):
    """Удаляет историю чата пользователя из Redis."""
    assert r is not None
    key = _redis_key(user_id)
    await r.delete(key)


def _count_tokens(messages: List[dict]) -> int:
    """Приблизительно подсчитывает количество токенов в истории сообщений."""
    # Approximate token count: sum(tokenize(content)) for each message content.
    # Good enough to trim history; exact chat-template token count is not required here.
    assert tokenizer is not None
    total = 0
    for m in messages:
        total += len(tokenizer.encode(m.get("content") or ""))
    return total


def _trim_to_budget(messages: List[dict]) -> List[dict]:
    """Обрезает историю сообщений, чтобы она укладывалась в заданный лимит токенов."""
    budget = max(1, MAX_CONTEXT_TOKENS - RESERVE_FOR_GENERATION)
    msgs = messages[:]
    while len(msgs) > MIN_KEEP_MESSAGES and _count_tokens(msgs) > budget:
        msgs.pop(1)  # Удаляем самое старое сообщение после системного промпта
    return msgs


async def _stream_vllm_chat(messages: List[dict], temperature: float, max_tokens: int):
    """Отправляет запрос к vLLM и асинхронно возвращает токены ответа."""
    headers = {"Authorization": f"Bearer {VLLM_KEY}"}
    payload = {
        "model": MODEL,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }

    async with httpx.AsyncClient(timeout=None) as client:
        async with client.stream(
            "POST",
            f"{VLLM_BASE}/chat/completions",
            headers=headers,
            json=payload,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line or not line.startswith("data:"):
                    continue
                data = line[len("data:"):].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                delta = chunk["choices"][0]["delta"].get("content")
                if delta:
                    yield delta

# ===== API эндпоинты =====

class ClearHistoryBody(BaseModel):
    user_id: str = Field(..., min_length=1, description="The unique identifier for the user.")

@app.post("/api/clear")
async def clear_http(body: ClearHistoryBody, _: Annotated[None, Depends(auth_dependency)]):
    """
    HTTP эндпоинт для очистки истории чата.
    POST /api/clear
    Body: {"user_id": "..."}
    Auth: X-API-Key or ?api_key=...
    """
    await _clear_user_history(body.user_id)
    return JSONResponse({"ok": True})


@app.websocket("/ws")
async def ws_chat(ws: WebSocket):
    """
    Основной эндпоинт для чата через WebSocket.
    Протокол сообщений:
      - chat message:
          {"type":"chat","user_id":"...","text":"...","temperature":0.2,"max_tokens":800}
      - clear history:
          {"type":"clear","user_id":"..."}
    Auth (optional): ?api_key=... or header X-API-Key
    """
    await ws.accept()
    try:
        # Аутентификация при подключении
        auth_dependency(ws, ws.query_params.get("api_key"))
    except HTTPException:
        await ws.send_json({"type": "error", "message": "Unauthorized"})
        await ws.close(code=4401)
        return

    try:
        while True:
            req = await ws.receive_json() # Ожидание нового сообщения от клиента

            user_id = (req.get("user_id") or "").strip()
            if not user_id:
                await ws.send_json({"type": "error", "message": "user_id required"})
                continue

            # Обработка разных типов сообщений
            msg_type = (req.get("type") or "chat").strip().lower()

            if msg_type == "clear":
                await _clear_user_history(user_id)
                await ws.send_json({"type": "cleared"})
                continue

            if msg_type != "chat":
                await ws.send_json({"type": "error", "message": f"Unknown type: {msg_type}"})
                continue

            # Обработка сообщения чата
            text = (req.get("text") or "").strip()
            temperature = float(req.get("temperature", 0.2))
            max_tokens = int(req.get("max_tokens", 800))

            if not text:
                await ws.send_json({"type": "error", "message": "Пустое сообщение."})
                continue

            # Загрузка истории, добавление нового сообщения и обрезка
            msgs = await _load_user_history(user_id)
            msgs.append({"role": "user", "content": text})
            msgs = _trim_to_budget(msgs)

            assistant_accum = ""
            try:
                # Стриминг ответа от модели и отправка токенов клиенту
                async for delta in _stream_vllm_chat(msgs, temperature=temperature, max_tokens=max_tokens):
                    assistant_accum += delta
                    await ws.send_json({"type": "token", "text": delta})
            except httpx.HTTPError as e:
                await ws.send_json({"type": "error", "message": f"Ошибка запроса к vLLM: {e}"})
                continue

            # Сохранение полного ответа ассистента в историю
            msgs.append({"role": "assistant", "content": assistant_accum})
            msgs = _trim_to_budget(msgs)
            await _save_user_history(user_id, msgs)

            await ws.send_json({"type": "done"}) # Сигнал о завершении ответа

    except WebSocketDisconnect:
        return
    except json.JSONDecodeError:
        # This case is less likely with receive_json, but good practice
        await ws.close(code=1003, reason="Invalid data format")
        return

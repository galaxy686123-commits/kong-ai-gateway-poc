#!/usr/bin/env python3
"""PoC 검증용 모의 서버 — 실물이 없는 백엔드를 대신해 결과가 정해진 시험을 가능하게 한다.

  POST /v1/chat/completions        OpenAI 호환 가짜 LLM. 받은 마지막 사용자 메시지를 그대로 답한다
                                   ("stream": true 면 SSE 로 나눠 보냄). 게이트웨이가 LLM 에 실제로
                                   무엇을 보냈는지(마스킹 여부 등)를 답변으로 확인할 수 있다.
                                   모델 이름에 down 이 들어 있거나, 요청 헤더 X-Mock-Down 에 그 모델 이름이
                                   오면 503 — 장애 대체(fallback) 시험용 (영역 ① /poc/1 의 주 모델 장애 재현).
                                   질문에 "점검 결과" 가 있으면 내부 IP·API 키·DB 접속 정보가 든 예시 답변
                                   (4-5 답변 속 내부 정보 마스킹 시험 — 질문에 넣으면 4-3 가드가 먼저 막는다)
  POST /fail/v1/chat/completions   항상 503
  POST /ocr                        업로드 본문의 크기·SHA-256 을 돌려줌 (?delay=초 로 지연)
  ANY  /agents/<이름>[/...]         받은 추적 헤더(X-Correlation-ID·traceparent)와 지연을 돌려줌 (?delay=초)
  POST /v1/traces                  OTLP/HTTP 수신 흉내 — 받은 건수만 센다
  POST /logs                       중앙 로그 저장소 흉내 — 최근 200건 보관
  GET  /stats                      위 수신 현황 · GET /logs 최근 로그 · GET /healthz

표준 라이브러리만 사용한다. 시험 전용 — 운영 백엔드가 아니다.
"""
import hashlib
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("PORT", "18090"))
STREAM_DELAY = float(os.getenv("MOCK_STREAM_DELAY", "0.02"))   # 스트리밍 조각 사이 간격(초)
FIRST_TOKEN_DELAY = float(os.getenv("MOCK_FIRST_TOKEN_DELAY", "0.2"))

_lock = threading.Lock()
STATS = {"traces": 0, "trace_bytes": 0, "logs": 0, "chat": 0, "ocr": 0, "agents": 0}
LOGS = []


def bump(key, n=1):
    with _lock:
        STATS[key] = STATS.get(key, 0) + n


# 4-5 시험용 — LLM 이 답변에 내부 정보를 흘린 상황 (게이트웨이가 가려야 한다)
SYSTEM_INFO_ANSWER = ("점검 결과: 서버 10.20.30.40 정상, API 키 sk-abcdefghij1234567890 만료 임박, "
                      "DB postgres://admin:secret@db:5432/app 연결 정상, password=hunter2")


def last_user_text(body):
    for m in reversed(body.get("messages") or []):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):   # 멀티모달 형식이면 글자 부분만
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c if isinstance(c, str) else ""
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code, payload, headers=None):
        raw = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                data += self.rfile.read(size)
                self.rfile.readline()
            return data
        return self.rfile.read(n) if n else b""

    def _delay(self, qs):
        try:
            d = float((qs.get("delay") or ["0"])[0])
        except ValueError:
            d = 0
        if d > 0:
            time.sleep(min(d, 900))
        return d

    # ── 가짜 LLM ─────────────────────────────────────────────
    def _chat(self, raw):
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            return self._json(400, {"error": {"message": "invalid json"}})
        bump("chat")
        text = last_user_text(body)
        answer = text if text else "(빈 질문)"
        if "점검 결과" in text:   # 4-5 시험 — 답변에 내부 정보가 섞여 나오는 상황
            answer = SYSTEM_INFO_ANSWER
        model = body.get("model") or "mock-llm"
        down = self.headers.get("X-Mock-Down", "")
        # 장애 대체(1-4) 시험 — 모델 이름에 down 이 있거나, 요청 헤더 X-Mock-Down 에 이 모델 이름이 오면 503
        if "down" in model or (down and down == model):
            return self._json(503, {"error": {"message": "mock model %s is down" % model}})
        p_tok, c_tok = max(1, len(text) // 2), max(1, len(answer) // 2)
        # 요청 헤더로 지연을 바꿀 수 있다 (verify.sh 가 지연 측정 전 Kong 을 빨리 데울 때 0 으로)
        first_delay = float(self.headers.get("X-Mock-First-Delay", FIRST_TOKEN_DELAY))
        stream_delay = float(self.headers.get("X-Mock-Stream-Delay", STREAM_DELAY))
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            def chunk(obj):
                data = ("data: " + (obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False)) + "\n\n").encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()

            time.sleep(first_delay)
            pieces = [answer[i:i + 8] for i in range(0, len(answer), 8)] or [""]
            for i, piece in enumerate(pieces):
                if i:
                    time.sleep(stream_delay)
                chunk({"id": "mock", "object": "chat.completion.chunk", "model": model,
                       "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
            chunk({"id": "mock", "object": "chat.completion.chunk", "model": model,
                   "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                   "usage": {"prompt_tokens": p_tok, "completion_tokens": c_tok, "total_tokens": p_tok + c_tok}})
            chunk("[DONE]")
            self.wfile.write(b"0\r\n\r\n")
            return
        time.sleep(first_delay)
        self._json(200, {
            "id": "mock", "object": "chat.completion", "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": answer}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": p_tok, "completion_tokens": c_tok, "total_tokens": p_tok + c_tok},
        })

    def do_POST(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        raw = self._body()
        if u.path == "/v1/chat/completions":
            return self._chat(raw)
        if u.path == "/fail/v1/chat/completions":
            return self._json(503, {"error": {"message": "mock primary model is down"}})
        if u.path == "/ocr":
            bump("ocr")
            d = self._delay(qs)
            return self._json(200, {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "delay": d})
        if u.path.startswith("/agents/"):
            return self._agent(u, qs)
        if u.path == "/v1/traces":
            bump("traces")
            bump("trace_bytes", len(raw))
            return self._json(200, {})
        if u.path == "/logs":
            bump("logs")
            try:
                entry = json.loads(raw or b"{}")
            except ValueError:
                entry = {"raw": raw[:200].decode("utf-8", "replace")}
            with _lock:
                LOGS.append(entry)
                del LOGS[:-200]
            return self._json(200, {})
        return self._json(404, {"error": "not found"})

    def _agent(self, u, qs):
        bump("agents")
        d = self._delay(qs)
        name = u.path.split("/")[2] if len(u.path.split("/")) > 2 else ""
        h = self.headers
        return self._json(200, {"agent": name, "delay": d,
                                "x-correlation-id": h.get("X-Correlation-ID"),
                                "traceparent": h.get("traceparent"),
                                "x-consumer-username": h.get("X-Consumer-Username")})

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if u.path in ("/healthz", "/"):
            return self._json(200, {"status": "ok"})
        if u.path == "/stats":
            with _lock:
                return self._json(200, dict(STATS))
        if u.path == "/logs":
            with _lock:
                return self._json(200, LOGS[-int((qs.get("n") or ["20"])[0]):])
        if u.path.startswith("/agents/"):
            return self._agent(u, qs)
        return self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"poc-mock :{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

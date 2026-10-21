#!/usr/bin/env python3
"""PoC 검증용 모의 서버 — 실물이 없는 백엔드를 대신해 결과가 정해진 시험을 가능하게 한다.

  POST /v1/chat/completions        OpenAI 호환 가짜 LLM. 받은 마지막 사용자 메시지를 그대로 답한다
                                   ("stream": true 면 SSE 로 나눠 보냄). 게이트웨이가 LLM 에 실제로
                                   무엇을 보냈는지(마스킹 여부 등)를 답변으로 확인할 수 있다.
                                   모델 이름에 down 이 들어 있거나, 요청 헤더 X-Mock-Down 에 그 모델 이름이
                                   오면 503 — 장애 대체(fallback) 시험용 (/poc 에 model=mock-llm 으로 보낼 때 주 모델 장애 재현).
                                   질문에 "점검 결과" 가 있으면 내부 IP·API 키·DB 접속 정보가 든 예시 답변
                                   (4-5 답변 속 내부 정보 마스킹 시험 — 질문에 넣으면 4-3 가드가 먼저 막는다)
  POST /fail/v1/chat/completions   항상 503
  POST /ocr                        업로드 본문의 크기·SHA-256 을 돌려줌 (?delay=초 로 지연)
  ANY  /agents/<이름>[/...]         받은 추적 헤더(X-Correlation-ID·traceparent)와 지연을 돌려줌 (?delay=초)
                                   ?call=b,c 면 이 에이전트의 키로 Kong 을 거쳐 그 에이전트들에게 A2A 작업을 맡기고
                                   (같은 X-Correlation-ID) 결과를 함께 돌려줌 — 에이전트 간 호출 통제 · 연쇄 추적 시험
  GET  /agents/<이름>/health        상태 점검용 — 200 {"status":"ok"} (Kong 이 에이전트 Upstream 을 점검하는 주소)
  POST /mock/agent-down?name=<이름> 그 에이전트를 장애로 — 그 에이전트 주소가 모두 503 (상태 점검 · 실제 호출 모두)
  POST /mock/agent-up?name=<이름>   장애 해제 (이 둘은 파드 안에서 모의 서버로 바로 — Kong 경로로는 닿지 않음)
       같은 주소로 A2A 에이전트도 흉내 낸다 (A2A 0.3 — Kong AI A2A Proxy 가 알아보는 형식):
         GET  …/.well-known/agent-card.json   Agent Card (url 은 이 서버 주소 — Kong 을 거치면 Kong 주소로 바뀌어야 함)
         POST …  JSON-RPC  message/send · message/stream · tasks/get · tasks/cancel
                 (message/send 에 configuration.blocking=false 면 바로 working 으로 답하고 ?delay=초(기본 3) 뒤 completed)
         POST …/v1/message:send · …/v1/message:stream · GET …/v1/tasks/<ID> · POST …/v1/tasks/<ID>:cancel   (REST)
  POST /v1/traces                  OTLP/HTTP 수신 흉내 — 받은 건수만 센다
  POST /logs                       중앙 로그 저장소 흉내 — 최근 200건 보관
  GET  /stats                      위 수신 현황 · GET /logs 최근 로그 · GET /healthz

표준 라이브러리만 사용한다. 시험 전용 — 운영 백엔드가 아니다.
"""
import hashlib
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("PORT", "18090"))
STREAM_DELAY = float(os.getenv("MOCK_STREAM_DELAY", "0.02"))   # 스트리밍 조각 사이 간격(초)
FIRST_TOKEN_DELAY = float(os.getenv("MOCK_FIRST_TOKEN_DELAY", "0.2"))

_lock = threading.Lock()
STATS = {"traces": 0, "trace_bytes": 0, "logs": 0, "chat": 0, "ocr": 0, "agents": 0, "a2a": 0}
LOGS = []
# 에이전트가 다른 에이전트를 부를 때 — Kong 주소와 에이전트마다의 호출 키 (start.sh 가 넣음: "a=<키> b=<키> c=<키>")
KONG_URL = os.getenv("MOCK_KONG_URL", "").rstrip("/")
AGENT_KEYS = dict(x.split("=", 1) for x in os.getenv("MOCK_AGENT_KEYS", "").split() if "=" in x and x.split("=", 1)[1])
DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # 파드의 HTTP 프록시 설정을 타지 않게 (Kong 은 파드 안)
TASKS = {}   # A2A 작업 — 작업 ID → {task, answer, done_at} (최근 200개)
DOWN = set()  # 장애로 만든 에이전트 이름 (POST /mock/agent-down · agent-up)


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


# ── 모의 A2A 에이전트 (A2A 0.3) ──────────────────────────────────
def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parts_text(parts):
    return " ".join(p.get("text", "") for p in parts or [] if isinstance(p, dict) and p.get("kind", "text") == "text").strip()


def a2a_new(agent, message, done_in):
    """작업을 만든다 (working) — done_in 초 뒤에 조회하면 끝나 있다(completed). 결과물은 받은 메시지를 그대로 담는다"""
    message = message if isinstance(message, dict) else {}
    tid = str(uuid.uuid4())
    task = {"kind": "task", "id": tid, "contextId": message.get("contextId") or str(uuid.uuid4()),
            "status": {"state": "working", "timestamp": now_iso()}, "history": [message] if message else [],
            "artifacts": [], "metadata": {"agent": "agent-" + agent}}
    answer = "agent-%s(모의 A2A 에이전트)가 받은 메시지: %s" % (agent, parts_text(message.get("parts")) or "(빈 메시지)")
    with _lock:
        TASKS[tid] = {"task": task, "answer": answer, "done_at": time.time() + done_in}
        while len(TASKS) > 200:
            TASKS.pop(next(iter(TASKS)))
    return tid


def a2a_view(tid, finish=False):
    """지금 작업 (사본) — 끝날 시각이 지났거나 finish 면 completed 로 끝내고 결과물을 붙인다. 없으면 None"""
    with _lock:
        e = TASKS.get(tid)
        if e is None:
            return None
        t = e["task"]
        if t["status"]["state"] == "working" and (finish or time.time() >= e["done_at"]):
            t["status"] = {"state": "completed", "timestamp": now_iso()}
            t["artifacts"] = [{"artifactId": str(uuid.uuid4()), "name": "answer", "parts": [{"kind": "text", "text": e["answer"]}]}]
        return json.loads(json.dumps(t))


def a2a_cancel(tid):
    """작업 취소 — 아직 진행 중일 때만 (끝난 작업이면 None, 없으면 False)"""
    with _lock:
        e = TASKS.get(tid)
        if e is None:
            return False
        if e["task"]["status"]["state"] != "working" or time.time() >= e["done_at"]:
            return None
        e["task"]["status"] = {"state": "canceled", "timestamp": now_iso()}
        return json.loads(json.dumps(e["task"]))


def agent_card(agent, host):
    base = "http://%s/agents/%s" % (host or "127.0.0.1:%d" % PORT, agent)
    return {
        "protocolVersion": "0.3.0", "name": "agent-%s (모의 A2A 에이전트)" % agent, "version": "1.0.0",
        "description": "PoC 시험용 — 받은 메시지를 그대로 돌려준다", "url": base, "preferredTransport": "JSONRPC",
        "additionalInterfaces": [{"url": base, "transport": "JSONRPC"}, {"url": base, "transport": "HTTP+JSON"}],
        "capabilities": {"streaming": True, "pushNotifications": False},
        "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"],
        "skills": [{"id": "echo", "name": "받은 메시지 돌려주기", "description": "시험용 — 받은 글을 그대로 답한다", "tags": ["poc"]}],
        "securitySchemes": {"apikey": {"type": "apiKey", "in": "header", "name": "apikey"}}, "security": [{"apikey": []}],
    }


def delegate(me, targets, cid):
    """이 에이전트(me)의 키로 Kong 을 거쳐 다른 에이전트들에게 A2A 작업(message/send)을 맡긴다 — 같은 추적 ID 를 이어 붙인다"""
    out = []
    for t in targets[:5]:
        rec = {"to": "agent-" + t}
        key = AGENT_KEYS.get(me)
        if not KONG_URL or not key:
            rec.update(status=0, message="이 에이전트의 Kong 주소 · 호출 키가 없음 (MOCK_KONG_URL · MOCK_AGENT_KEYS — bash start.sh 로 모의 서버를 다시 띄우세요)")
            out.append(rec)
            continue
        body = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "message/send",
                "params": {"message": {"kind": "message", "role": "user", "messageId": str(uuid.uuid4()),
                                       "parts": [{"kind": "text", "text": "agent-%s 가 맡긴 작업" % me}]}}}
        h = {"Content-Type": "application/json", "apikey": key}
        if cid:
            h["X-Correlation-ID"] = cid
        req = urllib.request.Request("%s/agents/%s" % (KONG_URL, t), data=json.dumps(body).encode(), headers=h, method="POST")
        try:
            with DIRECT.open(req, timeout=30) as r:
                code, raw = r.status, r.read()
        except urllib.error.HTTPError as e:
            code, raw = e.code, e.read()
        except OSError as e:
            code, raw = 0, json.dumps({"message": str(e)}).encode()
        try:
            d = json.loads(raw or b"{}")
        except ValueError:
            d = {"message": raw[:200].decode("utf-8", "replace")}
        rec["status"] = code
        res = d.get("result") if isinstance(d, dict) else None
        if code == 200 and isinstance(res, dict):
            rec["task_state"] = (res.get("status") or {}).get("state")
            rec["answer"] = " ".join(parts_text(a.get("parts")) for a in res.get("artifacts") or [] if isinstance(a, dict))
        else:
            err = d.get("error") if isinstance(d, dict) else None
            rec["message"] = (d.get("message") if isinstance(d, dict) else None) or (err.get("message") if isinstance(err, dict) else err)
        out.append(rec)
    return out


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
            return self._agent(u, qs, raw, "POST")
        if u.path in ("/mock/agent-down", "/mock/agent-up"):
            name = (qs.get("name") or [""])[0]
            if not re.fullmatch(r"[a-z0-9-]{1,40}", name):
                return self._json(400, {"error": "name=<에이전트 이름> (예: b)"})
            with _lock:
                (DOWN.add if u.path.endswith("down") else DOWN.discard)(name)
                down = sorted(DOWN)
            return self._json(200, {"down": down})
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

    def _num(self, qs, key, default):
        try:
            return max(0.0, min(float((qs.get(key) or [default])[0]), 900.0))
        except ValueError:
            return default

    def _sse(self, events):
        """SSE 로 하나씩 보낸다 — events 는 (보낼 객체, 보내기 전 쉴 초) 를 내는 반복자"""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for obj, wait in events:
            if wait:
                time.sleep(wait)
            data = ("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")

    def _a2a_stream(self, agent, message, wrap):
        """message/stream — 작업(working) → 상태 갱신 → 결과물 → 끝(completed, final)"""
        tid = a2a_new(agent, message, 3600)
        t = a2a_view(tid)
        ctx = t["contextId"]

        def events():
            yield wrap(t), 0
            yield wrap({"kind": "status-update", "taskId": tid, "contextId": ctx, "status": {"state": "working", "timestamp": now_iso()}, "final": False}), 0.2
            done = a2a_view(tid, finish=True)
            yield wrap({"kind": "artifact-update", "taskId": tid, "contextId": ctx, "artifact": done["artifacts"][0], "lastChunk": True}), 0.2
            yield wrap({"kind": "status-update", "taskId": tid, "contextId": ctx, "status": done["status"], "final": True}), 0.1
        self._sse(events())

    def _a2a_rpc(self, agent, req, qs):
        """A2A JSON-RPC — 오류도 HTTP 200 + error (JSON-RPC 관례)"""
        bump("a2a")
        rid, method, params = req.get("id"), req.get("method"), req.get("params") or {}
        ok = lambda r: self._json(200, {"jsonrpc": "2.0", "id": rid, "result": r})
        err = lambda c, m: self._json(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": c, "message": m}})
        if method == "message/send":
            blocking = (params.get("configuration") or {}).get("blocking", True) is not False
            done_in = self._num(qs, "delay", 0 if blocking else 3)
            tid = a2a_new(agent, params.get("message"), done_in)
            if blocking:
                time.sleep(done_in)
                return ok(a2a_view(tid, finish=True))
            return ok(a2a_view(tid))
        if method == "message/stream":
            return self._a2a_stream(agent, params.get("message"), lambda r: {"jsonrpc": "2.0", "id": rid, "result": r})
        if method == "tasks/get":
            t = a2a_view(str(params.get("id") or ""))
            return ok(t) if t else err(-32001, "Task not found")
        if method == "tasks/cancel":
            t = a2a_cancel(str(params.get("id") or ""))
            if t is False:
                return err(-32001, "Task not found")
            return ok(t) if t else err(-32002, "Task cannot be canceled")
        return err(-32601, "Method not found")

    def _a2a_rest(self, agent, sub, raw, qs):
        """A2A REST(HTTP+JSON) — …/v1/message:send · message:stream · tasks/<ID> · tasks/<ID>:cancel. 답했으면 True"""
        m = re.search(r"/v1/(message:send|message:stream|tasks/([^/:]+)(:cancel)?)$", sub)
        if not m:
            return False
        bump("a2a")
        self._a2a_rest_do(agent, m, raw, qs)
        return True

    def _a2a_rest_do(self, agent, m, raw, qs):
        if m.group(1).startswith("message:"):
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return self._json(400, {"error": {"message": "invalid json"}})
            if m.group(1) == "message:stream":
                return self._a2a_stream(agent, body.get("message"), lambda r: r)
            blocking = (body.get("configuration") or {}).get("blocking", True) is not False
            done_in = self._num(qs, "delay", 0 if blocking else 3)
            tid = a2a_new(agent, body.get("message"), done_in)
            if blocking:
                time.sleep(done_in)
            return self._json(200, a2a_view(tid, finish=blocking))
        tid = m.group(2)
        if m.group(3):
            t = a2a_cancel(tid)
            if t is False:
                return self._json(404, {"error": {"message": "Task not found"}})
            return self._json(200, t) if t else self._json(400, {"error": {"message": "Task cannot be canceled"}})
        t = a2a_view(tid)
        return self._json(200, t) if t else self._json(404, {"error": {"message": "Task not found"}})

    def _agent(self, u, qs, raw=b"", method="GET"):
        parts = u.path.split("/")
        name = parts[2] if len(parts) > 2 else ""
        sub = "/" + "/".join(parts[3:]) if len(parts) > 3 else ""
        if not re.fullmatch(r"[a-z0-9-]{1,40}", name):
            return self._json(404, {"error": "not found"})
        if name in DOWN:   # 모의 장애 — 상태 점검도 실제 호출도 503
            return self._json(503, {"error": "모의 장애 — 에이전트 %s 가 응답하지 못합니다" % name})
        if sub == "/health":
            return self._json(200, {"status": "ok", "agent": name})
        # A2A — Agent Card · JSON-RPC · REST
        if method == "GET" and sub in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
            bump("a2a")
            return self._json(200, agent_card(name, self.headers.get("Host")))
        if method == "POST" and raw[:1] == b"{":
            try:
                req = json.loads(raw)
            except ValueError:
                req = None
            if isinstance(req, dict) and req.get("jsonrpc"):
                return self._a2a_rpc(name, req, qs)
        if self._a2a_rest(name, sub, raw, qs):
            return
        # 일반 HTTP 에이전트 — 받은 추적 헤더를 돌려줌 (+ ?call= 이면 다른 에이전트에게 맡김)
        bump("agents")
        d = self._delay(qs)
        h = self.headers
        cid = h.get("X-Correlation-ID")
        out = {"agent": name, "delay": d, "x-correlation-id": cid, "traceparent": h.get("traceparent"),
               "x-consumer-username": h.get("X-Consumer-Username")}
        targets = [t for t in re.split(r"[,\s]+", (qs.get("call") or [""])[0]) if re.fullmatch(r"[a-z0-9-]{1,40}", t)]
        if targets:
            out["calls"] = delegate(name, targets, cid)
        return self._json(200, out)

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if u.path in ("/healthz", "/"):
            return self._json(200, {"status": "ok"})
        if u.path == "/stats":
            with _lock:
                return self._json(200, dict(STATS, down=sorted(DOWN)))
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

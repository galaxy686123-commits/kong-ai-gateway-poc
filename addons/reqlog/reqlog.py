#!/usr/bin/env python3
"""reqlog.py — 요청 로그(audit.log, 한 줄 = 호출 한 건)를 요청 기록 DB(reqlog)로 옮긴다 → Grafana 「요청 기록」이 표로 보여 준다.

질문 · 답변은 Kong Manager 에서 대상(Target)의 Log payloads 를 켰을 때만 로그에 있다(ai.proxy.payload.request · response).
스트리밍 답변도 Kong 이 하나로 이어 붙여 남긴다(choices[0].message.content).

  python3 reqlog.py          지금까지 쌓인 것을 옮기고 끝
  python3 reqlog.py --loop   10초마다 옮김 · 1시간마다 보관 기간이 지난 행을 지움 (start.sh 가 띄운다)

환경변수: LOGS · DATA_DIR · RUN_DIR · PG_BIN · PG_PORT · REQLOG_KEEP_DAYS(기본 7)
어디까지 옮겼는지는 유지 폴더의 state/reqlog.pos(파일 번호 · 위치)에 적는다 — 새 환경이 떠도 이어서 옮긴다.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

LOG = os.path.join(os.environ["LOGS"], "audit.log")
POS = os.path.join(os.environ["DATA_DIR"], "state", "reqlog.pos")
PSQL = [os.path.join(os.environ["PG_BIN"], "psql"), "-h", os.environ["RUN_DIR"], "-p", os.environ.get("PG_PORT") or "5432",
        "-U", "postgres", "-d", "reqlog", "-v", "ON_ERROR_STOP=1", "-qAt", "-f", "-"]
KEEP_DAYS = int(os.environ.get("REQLOG_KEEP_DAYS") or 7)
BATCH = 16 * 1024 * 1024           # 한 번에 읽는 양
MAX_FIELD = 2 * 1024 * 1024        # 본문 한 칸 상한 — 넘으면 잘라 둔다
SKIP_ROUTES = {"ai-embed"}         # 게이트웨이 안에서만 쓰는 임베딩 호출 — 사람이 볼 기록이 아니다
COLS = ("request_id", "ts", "consumer", "route", "method", "path", "status", "model", "provider",
        "prompt_tokens", "completion_tokens", "total_tokens", "latency_ms", "llm_latency_ms", "cache_status",
        "client_ip", "question", "answer", "request_body", "response_body")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def text_of(content):
    """OpenAI 메시지 content(글 또는 [{type, text} …]) → 글"""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for p in content:
            if isinstance(p, str):
                out.append(p)
            elif isinstance(p, dict):
                if p.get("type") in ("image_url", "input_image", "image"):
                    out.append("[이미지]")
                elif isinstance(p.get("text"), str):
                    out.append(p["text"])
        return "\n".join(x for x in out if x)
    return json.dumps(content, ensure_ascii=False)


def keep_indent(t):
    """줄 앞 공백 · 탭을 줄바꿈 없는 공백으로 — Grafana 표가 이어진 공백을 하나로 줄여 코드 들여쓰기가 사라지므로"""
    if not t:
        return t
    return re.sub(r"(?m)^[ \t]+", lambda m: m.group(0).replace("\t", "    ").replace(" ", "\u00a0"), t)


def question_of(body):
    """요청 본문 → 마지막 사용자 메시지 (임베딩 · 음성 등은 input · prompt)"""
    try:
        d = json.loads(body)
    except (TypeError, ValueError):
        return ""
    if not isinstance(d, dict):
        return ""
    msgs = d.get("messages")
    if isinstance(msgs, list):
        for m in reversed(msgs):
            if isinstance(m, dict) and m.get("role") == "user":
                return text_of(m.get("content"))
        return ""
    for k in ("input", "prompt"):
        if k in d:
            return text_of(d[k])
    return ""


def answer_of(body):
    """응답 본문 → 답변 글 (도구 호출 · 오류도 글로)"""
    try:
        d = json.loads(body)
    except (TypeError, ValueError):
        return body or ""
    if not isinstance(d, dict):
        return ""
    choices = d.get("choices")
    if isinstance(choices, list) and choices and isinstance(choices[0], dict):
        c = choices[0]
        m = c.get("message") or c.get("delta") or {}
        t = text_of(m.get("content")) if isinstance(m, dict) else ""
        for call in (m.get("tool_calls") or []) if isinstance(m, dict) else []:
            f = (call or {}).get("function") or {}
            t += ("\n" if t else "") + "[도구 호출] %s(%s)" % (f.get("name", "?"), f.get("arguments", ""))
        return t or (c.get("text") or "")
    err = d.get("error")
    if err:
        return "[오류] " + (err.get("message") if isinstance(err, dict) and err.get("message") else json.dumps(err, ensure_ascii=False))
    if isinstance(d.get("message"), str):
        return "[오류] " + d["message"]
    if isinstance(d.get("text"), str):
        return d["text"]
    return ""


def as_int(v):
    """숫자 칸 — 정수로 (소수는 반올림, 숫자가 아니면 비움)"""
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(round(v))
    if isinstance(v, str) and v.strip().lstrip("-").isdigit():
        return int(v)
    return None


def row_of(line):
    try:
        d = json.loads(line)
    except ValueError:
        return None
    if not isinstance(d, dict) or not d.get("started_at"):
        return None
    route = (d.get("route") or {}).get("name") or ""
    if route in SKIP_ROUTES:
        return None
    req, resp = d.get("request") or {}, d.get("response") or {}
    ai = d.get("ai") if isinstance(d.get("ai"), dict) else {}
    ai = ai.get("proxy") or (next(iter(ai.values()), {}) if ai else {})
    ai = ai if isinstance(ai, dict) else {}
    meta, usage, cache, payload = (ai.get(k) if isinstance(ai.get(k), dict) else {} for k in ("meta", "usage", "cache", "payload"))
    model = meta.get("response_model") or meta.get("request_model") or None
    rq, rs = payload.get("request"), payload.get("response")
    rq = rq if isinstance(rq, str) else (json.dumps(rq, ensure_ascii=False) if rq else None)
    rs = rs if isinstance(rs, str) else (json.dumps(rs, ensure_ascii=False) if rs else None)
    rid = req.get("id") or d.get("correlation_id") or hashlib.sha1(line.encode("utf-8", "replace")).hexdigest()
    lat = d.get("latencies") or {}
    return {
        "request_id": rid,
        "ts": d["started_at"] / 1000.0,
        "consumer": (d.get("consumer") or {}).get("username"),
        "route": route or None,
        "method": req.get("method"),
        "path": (req.get("uri") or "").split("?", 1)[0] or None,
        "status": as_int(resp.get("status")),
        "model": None if model == "UNSPECIFIED" else model,
        "provider": meta.get("provider_name"),
        "prompt_tokens": as_int(usage.get("prompt_tokens")),
        "completion_tokens": as_int(usage.get("completion_tokens")),
        "total_tokens": as_int(usage.get("total_tokens")),
        "latency_ms": as_int(lat.get("request")),
        "llm_latency_ms": as_int(meta.get("llm_latency")),
        "cache_status": cache.get("cache_status"),
        "client_ip": d.get("client_ip"),
        "question": keep_indent(question_of(rq)) if rq else None,
        "answer": keep_indent(answer_of(rs)) if rs else None,
        "request_body": rq,
        "response_body": rs,
    }


def lit(v):
    """SQL 값 — 글은 작은따옴표만 겹친다 (standard_conforming_strings = on)"""
    if v is None or v == "":
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    s = str(v).replace("\x00", "")
    if len(s) > MAX_FIELD:
        s = s[:MAX_FIELD] + "\n…(이후 생략)"
    return "'" + s.replace("'", "''") + "'"


def insert_sql(rows):
    out = ["BEGIN;"]
    for r in rows:
        vals = [("to_timestamp(%r)" % r["ts"]) if c == "ts" else lit(r[c]) for c in COLS]
        out.append("INSERT INTO requests (%s) VALUES (%s) ON CONFLICT (request_id) DO NOTHING;" % (", ".join(COLS), ", ".join(vals)))
    out.append("COMMIT;")
    return "\n".join(out).encode("utf-8")


def psql(sql):
    env = dict(os.environ, PGOPTIONS="-c client_min_messages=warning")
    p = subprocess.run(PSQL, input=sql, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "replace").strip()[-400:])
    return p.stdout.decode("utf-8", "replace")


def load_pos():
    try:
        with open(POS) as f:
            ino, off = f.read().split()
        return int(ino), int(off)
    except (OSError, ValueError):
        return None, 0


def save_pos(ino, off):
    os.makedirs(os.path.dirname(POS), exist_ok=True)
    with open(POS + ".tmp", "w") as f:
        f.write("%d %d\n" % (ino, off))
    os.replace(POS + ".tmp", POS)


def ingest():
    """새로 쌓인 줄을 옮긴다 → 옮긴 행 수"""
    try:
        st = os.stat(LOG)
    except OSError:
        return 0
    ino, off = load_pos()
    if ino != st.st_ino or off > st.st_size:   # 처음이거나, 로그 파일을 지우고 새로 만듦
        off = 0
    oldest = time.time() - KEEP_DAYS * 86400
    total = 0
    with open(LOG, "rb") as f:
        while off < st.st_size:
            f.seek(off)
            chunk = f.read(BATCH)
            end = chunk.rfind(b"\n")
            if end < 0:
                if len(chunk) < BATCH:
                    break                          # 아직 다 쓰지 않은 마지막 줄 — 다음 번에
                rest = f.readline()                # 한 줄이 너무 길다 — 건너뜀
                off += len(chunk) + len(rest)
                log("한 줄이 %dMB 를 넘어 건너뜀" % (BATCH // 1048576))
                save_pos(st.st_ino, off)
                continue
            rows = []
            for line in chunk[:end + 1].splitlines():
                r = row_of(line.decode("utf-8", "replace"))
                if r and r["ts"] >= oldest:
                    rows.append(r)
            if rows:
                psql(insert_sql(rows))
            off += end + 1
            save_pos(st.st_ino, off)
            total += len(rows)
    return total


def clean():
    psql(("DELETE FROM requests WHERE ts < now() - interval '%d days';" % KEEP_DAYS).encode())


def main():
    if "--loop" not in sys.argv:
        n = ingest()
        clean()
        print("옮김 %d건" % n)
        return
    log("시작 — %s → DB reqlog (10초마다 · %d일 보관)" % (LOG, KEEP_DAYS))
    last_clean, moved, last_report = 0.0, 0, time.time()
    while True:
        try:
            moved += ingest()
            if time.time() - last_clean > 3600:
                clean()
                last_clean = time.time()
            if time.time() - last_report > 3600:
                if moved:
                    log("지난 1시간 %d건 옮김" % moved)
                moved, last_report = 0, time.time()
        except Exception as e:  # DB 가 잠깐 내려간 때 등 — 다음 번에 다시 (위치를 옮기지 않았으니 빠지는 줄 없음)
            log("옮기지 못함 — %s" % e)
        time.sleep(10)


if __name__ == "__main__":
    main()

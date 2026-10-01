#!/usr/bin/env python3
"""한국어 PII 가드레일 서비스 — Kong ai-custom-guardrail 백엔드.

2계층 탐지:
  1) 정규식 계층 — 형식이 정해진 식별번호. 주민/외국인등록번호는 체크섬까지 검증해
     오탐을 줄인다. Kong 내장 ai-prompt-guard 는 deny_patterns 가 10개로 제한되지만
     여기는 제한이 없다.
  2) LLM 계층 — "고객명 + 계약정보 결합 문장"처럼 형식이 없는 문맥형 개인정보.
     정규식이 아무것도 못 잡았을 때만 호출해 지연을 아낀다.

Kong 계약:
  POST /check  {"text": "..."}
  → {"block": bool, "reason": str, "detail": str, "layer": str}
"""
import json
import os
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 문맥 판정(2계층)은 LLM_ENABLED=true 이고 LLM_URL 을 줄 때만 켜진다 (OpenAI 호환 chat completions)
LLM_URL = os.getenv("LLM_URL", "")
LLM_MODEL = os.getenv("LLM_MODEL", "")
LLM_TIMEOUT = float(os.getenv("LLM_TIMEOUT", "8"))
LLM_ENABLED = os.getenv("LLM_ENABLED", "false").lower() == "true" and bool(LLM_URL)
PORT = int(os.getenv("PORT", "8080"))
# 답변 검사(OUTPUT)에서 막을 유해 표현 — 쉼표로 구분. 고객 정책 목록으로 바꿔 쓴다.
HARMFUL_WORDS = [w.strip() for w in os.getenv(
    "HARMFUL_WORDS",
    "폭탄 제조,폭발물 제조,마약 제조,살인 청부,자살 방법,인종 차별,혐오 발언,테러 계획"
).split(",") if w.strip()]

# ── 1계층: 정규식 ────────────────────────────────────────────────
# (이름, 사유코드, 정규식, 처리). Kong 의 10개 제한과 무관하게 얼마든지 늘릴 수 있다.
#   BLOCK — 마스킹해도 요청 자체가 부적절한 식별번호·금융정보
#   MASK  — 업무 문맥에 흔히 섞여 들어오는 연락처류. 가리고 통과시켜야 업무가 된다
BLOCK, MASK = "block", "mask"
PATTERNS = [
    ("주민등록번호",     "rrn",        re.compile(r"\d{6}\s*[-–]\s*[1-4]\d{6}"), BLOCK),
    ("외국인등록번호",   "frn",        re.compile(r"\d{6}\s*[-–]\s*[5-8]\d{6}"), BLOCK),
    ("여권번호",         "passport",   re.compile(r"\b[MSRODmsrod]\d{8}\b"), BLOCK),
    ("운전면허번호",     "driver",     re.compile(r"\b\d{2}\s*-\s*\d{2}\s*-\s*\d{6}\s*-\s*\d{2}\b"), BLOCK),
    ("휴대전화번호",     "mobile",     re.compile(r"\b01[016789]\s*[-–.]\s*\d{3,4}\s*[-–.]\s*\d{4}\b"), MASK),
    ("유선전화번호",     "landline",   re.compile(r"\b0(?:2|[3-6][1-5])\s*[-–.]\s*\d{3,4}\s*[-–.]\s*\d{4}\b"), MASK),
    ("카드번호",         "card",       re.compile(r"\b(?:\d{4}\s*[-–]\s*){3}\d{4}\b"), BLOCK),
    ("사업자등록번호",   "biz",        re.compile(r"\b\d{3}\s*-\s*\d{2}\s*-\s*\d{5}\b"), MASK),
    ("계좌번호",         "account",    re.compile(r"(?:계좌|예금주|account)\D{0,10}\d{2,3}[-\s]\d{2,6}[-\s]\d{2,7}"), BLOCK),
    ("이메일",           "email",      re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]{2,}\b"), MASK),
    # ── 업종별(보험) 채번 규칙 ──────────────────────────────────
    # ⚠️ 아래 3종은 데모용 예시 형식이다. 실배포 시 고객사 실제 채번 규칙으로 교체한다.
    #   보험계약번호: 라벨(계약/증권/보험) + 8~20자리 영숫자(하이픈 포함)
    #   증권번호:     라벨 없이도 잡히는 P/보험 접두 형식(여권 P00000000 과 구분 위해 라벨 우선)
    #   사고번호:     라벨(사고/claim) + 연도-일련번호
    ("보험계약번호",     "contract_no", re.compile(r"(?:계약|보험|contract|policy)\s*(?:번호|No\.?)?\s*[:\-]?\s*[A-Za-z]{0,3}[-]?\d{2,4}[-]?\d{4,10}"), BLOCK),
    ("증권번호",         "policy_no",   re.compile(r"(?:증권|policy)\s*(?:번호|No\.?)?\s*[:\-]?\s*[A-Za-z]{0,2}\d{7,12}"), BLOCK),
    # 영문 접두 뒤에 하이픈이 오는 형식(AC-2024-00123)도 잡는다 — 보험계약번호와 같은 구조
    ("사고번호",         "claim_no",    re.compile(r"(?:사고|접수|claim)\s*(?:번호|No\.?)?\s*[:\-]?\s*[A-Za-z]{0,3}[-]?\d{2,4}[-]?\d{3,8}"), BLOCK),
    # ── 그 외 업종 확장 슬롯 ────────────────────────────────────
    # 주문번호·환자번호·회원번호 등도 같은 형식으로 추가. 개수 제한 없음.
    ("상세주소",         "address",    re.compile(r"[가-힣]+(?:시|도)\s*[가-힣]+(?:시|군|구)\s*[가-힣0-9]+(?:로|길|동)\s*\d+"), MASK),
    ("API 키 유출",      "credential", re.compile(r"\b(?:sk|ak)-[A-Za-z0-9_\-]{20,}\b"), BLOCK),
    ("프롬프트 인젝션",  "injection",  re.compile(r"(?i)(?:ignore|disregard|forget)\s+(?:all\s+)?(?:previous|above|prior)\s+(?:instruction|prompt|rule)"), BLOCK),
    ("시스템 프롬프트 탈취", "sysprompt", re.compile(r"(?i)(?:시스템\s*프롬프트|system\s+prompt).{0,20}(?:알려|보여|출력|공개|reveal|show|print)"), BLOCK),
]

RRN_WEIGHTS = [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]


def rrn_checksum_ok(text: str) -> bool:
    """주민/외국인등록번호 체크섬. 임의의 13자리 숫자 오탐을 걸러낸다."""
    d = [int(c) for c in re.sub(r"\D", "", text)]
    if len(d) != 13:
        return False
    total = sum(a * b for a, b in zip(d[:12], RRN_WEIGHTS))
    return (11 - total % 11) % 10 == d[12]


def regex_scan(text: str):
    """형식이 맞으면 유형별 처리(BLOCK/MASK)를 결정하고, 마스킹본을 함께 만든다.

    체크섬은 차단 여부가 아니라 심각도 표시로만 쓴다 — DLP 관점에서 체크섬이
    틀린 주민번호도 유출되면 곤란하고, 오탐(임의의 13자리)은 하이픈+성별자리
    형식 제약으로 이미 충분히 걸러진다.

    반환: (hits, masked_text) — masked_text 는 MASK 유형만 치환한 결과.
    같은 원본 값에는 같은 placeholder 를 부여해 문맥 일관성을 유지한다.
    """
    hits, masked, seen = [], text, {}
    for name, code, rx, action in PATTERNS:
        found = list(rx.finditer(text))
        if not found:
            continue
        hit = {"name": name, "code": code, "match": found[0].group()[:40],
               "action": action, "count": len(found)}
        if code in ("rrn", "frn"):
            hit["checksum"] = "valid" if rrn_checksum_ok(found[0].group()) else "invalid"
            if hit["checksum"] == "invalid":
                hit["name"] = f"{name}(형식일치·체크섬불일치)"
        hits.append(hit)
        if action == MASK:
            for m in found:
                raw = m.group()
                if raw not in seen:
                    seen[raw] = f"[{name}{len([k for k, v in seen.items() if v.startswith('[' + name)]) + 1}]"
                masked = masked.replace(raw, seen[raw])
    return hits, masked


# ── 2계층: LLM 문맥 판정 ──────────────────────────────────────────
SYSTEM = (
    "너는 한국 기업의 개인정보 탐지기다. 사용자 문장에 '특정 개인을 식별할 수 있는 정보'와 "
    "'그 개인에게 귀속되는 정보(계약·거래·인사·건강·금융 등)'가 결합되어 있는지 판정한다.\n"
    "결합되어 있으면 개인정보다. 특정 개인을 지목하지 않는 일반적인 제도·절차·규정 문의는 개인정보가 아니다.\n"
    '반드시 이 JSON 형식으로만 답한다: {"pii": true 또는 false, "reason": "짧은 한국어 사유"}\n'
    "예) '홍길동 사원의 올해 인사평가 결과와 연봉 알려줘' → "
    '{"pii": true, "reason": "실명과 개인 인사정보 결합"}\n'
    "예) '인사평가는 어떤 기준으로 산정되나요' → "
    '{"pii": false, "reason": "일반 제도 문의"}'
)


def llm_scan(text: str):
    body = json.dumps({
        "model": LLM_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": text[:2000]},
        ],
        "temperature": 0,
        "max_tokens": 120,
        # qwen3.8 은 thinking 이 기본 ON 이라 추론 토큰으로 8초 타임아웃을 넘김 → 명시적 OFF
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(
        LLM_URL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT) as r:
        msg = json.load(r)["choices"][0]["message"]
    # thinking 이 켜진 채로 잘리면 content 가 null 로 오고 본문은 reasoning 에 남는다
    content = msg.get("content") or msg.get("reasoning") or ""
    # 모델이 코드펜스나 설명을 덧붙여도 첫 JSON 객체만 뽑아낸다
    m = re.search(r"\{.*?\}", content, re.S)
    if not m:
        return None
    return json.loads(m.group())


# 게이트웨이 pre-function 이 먼저 치환해 둔 유형 라벨 ([연락처1], [이메일2] 등).
# 이미 비식별화된 자리이므로 검사 대상에서 제거 — 유형명을 보고 오판하는 것을 막는다.
PLACEHOLDER = re.compile(r"\[(?:연락처|이메일|사업자번호|주민번호|비식별)\d+\]")



# ── OTel 스팬 방출 (2026-08-20): 가드 왕복 원문(raw)을 Arize 트레이스에 붙인다 ──
# Kong 이 전파한 traceparent 로 같은 트레이스에 자식 스팬으로 결합.
# 설정은 env: ARIZE_SPACE_ID / ARIZE_API_KEY (없으면 방출 안 함 — 기능 무영향)
import threading
import time as _time
import secrets as _secrets

_ARIZE_URL = "https://otlp.arize.com/v1/traces"
_ARIZE_SPACE = os.environ.get("ARIZE_SPACE_ID", "")
_ARIZE_KEY = os.environ.get("ARIZE_API_KEY", "")


def _emit_span(traceparent, text_in, verdict_out, t0_ns, t1_ns):
    if not (_ARIZE_SPACE and _ARIZE_KEY and traceparent):
        return
    try:
        parts = traceparent.split("-")
        trace_id, parent_id = parts[1], parts[2]
        span = {
            "traceId": trace_id,
            "spanId": _secrets.token_hex(8),
            "parentSpanId": parent_id,
            "name": "guard.korean-pii",
            "kind": 1,
            "startTimeUnixNano": str(t0_ns),
            "endTimeUnixNano": str(t1_ns),
            "attributes": [
                {"key": "openinference.span.kind", "value": {"stringValue": "GUARDRAIL"}},
                {"key": "input.value", "value": {"stringValue": text_in[:2000]}},
                {"key": "output.value", "value": {"stringValue": verdict_out[:2000]}},
                {"key": "service.impl", "value": {"stringValue": "korean-pii-guard"}},
            ],
        }
        payload = json.dumps({"resourceSpans": [{
            "resource": {"attributes": [
                {"key": "model_id", "value": {"stringValue": "kong-ai-gateway"}},
                {"key": "service.name", "value": {"stringValue": "korean-pii-guard"}},
            ]},
            "scopeSpans": [{"scope": {"name": "korean-pii-guard"}, "spans": [span]}],
        }]}).encode()
        req = urllib.request.Request(_ARIZE_URL, data=payload, headers={
            "Content-Type": "application/json",
            "space_id": _ARIZE_SPACE, "api_key": _ARIZE_KEY})
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass  # 관측 실패가 판정을 막으면 안 된다


def emit_span_async(*args):
    threading.Thread(target=_emit_span, args=args, daemon=True).start()


def inspect(text: str):
    text = PLACEHOLDER.sub(" ", text)
    hits, masked = regex_scan(text)
    blocked = [h for h in hits if h["action"] == BLOCK]
    if blocked:
        names = ", ".join(h["name"] for h in blocked)
        return {
            "block": True,
            "reason": blocked[0]["code"],
            "detail": f"개인정보 탐지({len(blocked)}종): {names}",
            "layer": "regex",
            "masked": False,
        }
    maskable = [h for h in hits if h["action"] == MASK]
    if maskable:
        # 차단 대상은 없고 가릴 것만 있다 → LLM 에는 마스킹본이 가고 업무는 계속된다
        names = ", ".join(h["name"] for h in maskable)
        # 실제 프롬프트 치환은 Kong pre-function(`*--mask-pii`)이 가드레일 앞단에서 수행한다.
        # (ai-custom-guardrail 의 allow_masking 은 INPUT 단계에서 서비스가 준 텍스트로
        #  치환해 주지 않는다 — 실측 확인). 여기서는 통과시키고 무엇을 가렸는지만 알린다.
        return {
            "block": False,
            "reason": "masked",
            "detail": f"마스킹({len(maskable)}종): {names}",
            "layer": "regex",
            "masked": True,
            "text": masked,
        }
    if LLM_ENABLED and len(text.strip()) >= 8:
        try:
            v = llm_scan(text)
            if v and v.get("pii"):
                return {
                    "block": True,
                    "reason": "context_pii",
                    "detail": f"문맥 개인정보: {v.get('reason', '')}"[:200],
                    "layer": "llm",
                    "masked": False,
                }
        except Exception as e:
            # 판정 실패가 곧 차단이어서는 안 된다. Kong 의 stop_on_error 가 정책을 결정한다.
            # 예외 종류를 좁게 잡았다가 응답 스키마가 어긋나면(content=null) TypeError 가 새어
            # 나가 커넥션이 끊기고 게이트웨이가 500 을 냈다 — 판정 경로는 무엇이 터지든 삼킨다.
            return {"block": False, "reason": "llm_error", "masked": False,
                    "detail": f"LLM 판정 실패: {type(e).__name__}", "layer": "llm"}
    return {"block": False, "reason": "clean", "detail": "탐지 없음",
            "layer": "regex", "masked": False}


def inspect_output(text: str):
    found = [w for w in HARMFUL_WORDS if w in text]
    if found:
        return {"block": True, "reason": "harmful_output",
                "detail": f"유해 표현 탐지({len(found)}종): {', '.join(found)}",
                "layer": "output", "masked": False}
    return {"block": False, "reason": "clean", "detail": "탐지 없음", "layer": "output", "masked": False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, payload: dict):
        raw = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path in ("/healthz", "/"):
            self._send(200, {"status": "ok", "llm": LLM_ENABLED, "patterns": len(PATTERNS)})
        elif self.path == "/policy":
            # 어떤 정책이 들어 있는지 콘솔이 그대로 읽어 보여준다 (탐지 규칙은 비밀이 아니다)
            self._send(200, {
                "layer1": {
                    "engine": "정규식",
                    "latency_ms": "~20",
                    "note": "Kong 내장 ai-prompt-guard 는 deny_patterns 10개 상한 — 여기는 제한 없음",
                    "patterns": [
                        {"name": n, "code": c, "regex": rx.pattern, "action": a,
                         "checksum": c in ("rrn", "frn")}
                        for n, c, rx, a in PATTERNS],
                },
                "layer2": {
                    "engine": "LLM 문맥 판정",
                    "model": LLM_MODEL,
                    "enabled": LLM_ENABLED,
                    "latency_ms": "~300",
                    "when": "1계층이 아무것도 못 잡았을 때만 호출",
                    "rule": SYSTEM,
                },
                "policy": "유형별 처리 — block=식별번호·금융정보는 차단, "
                          "mask=연락처류는 [비식별n] 으로 가리고 통과(업무 연속성). "
                          "실제 프롬프트 치환은 Kong pre-function(*--mask-pii)이 이 가드레일 "
                          "앞단에서 수행하고, 여기서는 치환 후 텍스트를 다시 검사한다. "
                          "체크섬은 차단 여부가 아니라 심각도 표시용",
                "actions": {"block": sum(1 for *_, a in PATTERNS if a == BLOCK),
                            "mask": sum(1 for *_, a in PATTERNS if a == MASK)},
            })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/check":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, TypeError):
            return self._send(400, {"error": "invalid json"})
        text = data.get("text") or ""
        if not isinstance(text, str):
            text = str(text)
        _t0 = _time.time_ns()
        # Kong ai-custom-guardrail 이 답변을 검사할 때는 source=OUTPUT 을 보낸다 → 유해 표현만 본다
        # (답변 속 시스템 정보는 게이트웨이의 post-function 이 마스킹한다)
        _verdict = inspect_output(text) if data.get("source") == "OUTPUT" else inspect(text)
        _t1 = _time.time_ns()
        self._send(200, _verdict)
        # 왕복 원문을 게이트웨이 트레이스에 자식 스팬으로 (비동기 — 응답 지연 0)
        emit_span_async(self.headers.get("traceparent"),
                        text, json.dumps(_verdict, ensure_ascii=False), _t0, _t1)

    def log_message(self, fmt, *args):
        pass  # 접근 로그는 Kong 이 남긴다. 프롬프트 원문을 여기 남기지 않는다.


if __name__ == "__main__":
    print(f"korean-pii-guard :{PORT} (patterns={len(PATTERNS)}, llm={LLM_ENABLED}, masking=on)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

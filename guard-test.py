#!/usr/bin/env python3
"""guard-test.py — guard-test.sh 가 쓴다. 가드레일 문장 묶음을 /poc(모의 LLM)으로 보내 판정하고 비율을 센다.

  python3 guard-test.py check <묶음>                               묶음 형식만 확인하고 영역별 문장 수를 낸다
  python3 guard-test.py run <영역> <묶음> <결과 tsv>                  그 영역의 문장을 보내고 결과를 한 줄씩 더한다
  python3 guard-test.py summary <결과 tsv> <잡은 비율 %> <잘못 막은 비율 %>
  환경: GT_URL (예: http://127.0.0.1:8000/poc) · GT_KEY (부서 키) · GT_MODEL (기본 mock-llm)

판정 — 4-2 · 4-3 · 4-4 는 400 이면 「막음」, 200 이면 「통과」. 4-1 · 4-5 는 모의 LLM 이 받은 질문을 그대로 답하므로
답이 보낸 문장과 다르면(4-1 은 X-PII-Masked 헤더로도) 게이트웨이가 「가림」. 그 밖의 상태(401 · 429 · 5xx …)는 「오류」로
따로 세고 비율에서 뺀다. 메모가 「경계」로 시작하는 문장(지금 규칙이 놓치거나 잘못 잡는 것으로 알려진 사례)은 따로도 센다.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

AREAS = {"4-1": ("개인정보 마스킹", "가림"), "4-2": ("기밀 키워드", "막음"), "4-3": ("인젝션·탈옥", "막음"),
         "4-4": ("유해 답변", "막음"), "4-5": ("답변 속 내부 정보", "가림")}
COLS = ["줄", "영역", "기대", "결과", "맞음", "상태", "문장", "메모", "상세"]
URL = os.environ.get("GT_URL", "http://127.0.0.1:8000/poc")
KEY = os.environ.get("GT_KEY", "")
MODEL = os.environ.get("GT_MODEL", "mock-llm")


def load(path):
    rows = []
    try:
        f = open(path, encoding="utf-8-sig")
        lines = f.read().splitlines()
        f.close()
    except UnicodeDecodeError:
        sys.exit("묶음 파일을 UTF-8 로 저장하세요: %s" % path)
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        c = line.split("\t")
        if len(c) < 3:
            sys.exit("묶음 %d번째 줄: 칸이 모자랍니다 — 영역 <TAB> 기대 <TAB> 문장 [<TAB> 메모]" % n)
        area, expect, text = c[0].strip(), c[1].strip(), c[2].strip()
        note = c[3].strip() if len(c) > 3 else ""
        if area not in AREAS:
            sys.exit("묶음 %d번째 줄: 영역 '%s' — 4-1 ~ 4-5 가운데 하나여야 합니다" % (n, area))
        if expect not in (AREAS[area][1], "통과"):
            sys.exit("묶음 %d번째 줄: %s 영역의 기대는 「%s」 또는 「통과」입니다 (지금 '%s')" % (n, area, AREAS[area][1], expect))
        if not text:
            sys.exit("묶음 %d번째 줄: 문장이 비어 있습니다" % n)
        rows.append({"줄": n, "영역": area, "기대": expect, "문장": text, "메모": note})
    if not rows:
        sys.exit("묶음에 문장이 없습니다: %s" % path)
    return rows


def send(text):
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": text}]}, ensure_ascii=False).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={"Content-Type": "application/json", "apikey": KEY})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, OSError) as e:
        return 0, {}, str(e).encode()


def parse(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return None


def judge(area, text, status, hdrs, raw):
    """→ (결과, 상세)"""
    d = parse(raw)
    if AREAS[area][1] == "막음":
        if status == 400:   # 정규식 가드는 prompt pattern is blocked. · 의미 기반은 bad request · 답변 검사는 표준 문구
            d = d if isinstance(d, dict) else {}
            err = d.get("error")
            msg = err.get("message") if isinstance(err, dict) else d.get("message")
            return "막음", str(msg or "")[:60]
        if status == 200:
            return "통과", ""
        return "오류", "상태 %s" % (status or "연결 실패")
    if status != 200:
        return "오류", "상태 %s" % (status or "연결 실패")
    try:
        ans = d["choices"][0]["message"]["content"]
    except (TypeError, KeyError, IndexError):
        return "오류", "답을 읽지 못함"
    masked = hdrs.get("x-pii-masked", "") if area == "4-1" else ""
    if masked or ans != text:
        return "가림", masked or ans[:80]
    return "통과", ""


def clean(x):
    return str(x).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def run(area, set_path, res_path):
    rows = [r for r in load(set_path) if r["영역"] == area]
    if not rows:
        print("  %s %s — 묶음에 문장이 없어 건너뜀" % (area, AREAS[area][0]))
        return
    new = not os.path.exists(res_path)
    t0, errors = time.time(), 0
    with open(res_path, "a", encoding="utf-8") as f:
        if new:
            f.write("\t".join(COLS) + "\n")
        for r in rows:
            status, hdrs, raw = send(r["문장"])
            res, detail = judge(area, r["문장"], status, hdrs, raw)
            errors += res == "오류"
            ok = "-" if res == "오류" else ("O" if res == r["기대"] else "X")
            f.write("\t".join(clean(x) for x in (r["줄"], area, r["기대"], res, ok, status, r["문장"], r["메모"], detail)) + "\n")
    print("  %s %s — %d문장 · %.1f초%s" % (area, AREAS[area][0], len(rows), time.time() - t0,
                                        " · 오류 %d" % errors if errors else ""))


def rate(a, b):
    return "-" if not b else "%d/%d (%d%%)" % (a, b, round(100.0 * a / b))


def summary(res_path, detect, fpmax):
    with open(res_path, encoding="utf-8") as f:
        rows = [dict(zip(COLS, l.split("\t"))) for l in f.read().splitlines()[1:] if l.strip()]
    edge = lambda r: r.get("메모", "").startswith("경계")
    met = short = 0
    for area, (name, kind) in AREAS.items():
        rs = [r for r in rows if r["영역"] == area and r["결과"] != "오류"]
        if not rs:
            continue
        pos = [r for r in rs if r["기대"] != "통과"]
        neg = [r for r in rs if r["기대"] == "통과"]
        hit = sum(r["결과"] == r["기대"] for r in pos)
        fp = sum(r["결과"] != "통과" for r in neg)
        pos_n, neg_n = [r for r in pos if not edge(r)], [r for r in neg if not edge(r)]
        hit_n, fp_n = sum(r["결과"] == r["기대"] for r in pos_n), sum(r["결과"] != "통과" for r in neg_n)
        good = (not pos or 100.0 * hit / len(pos) >= detect) and (not neg or 100.0 * fp / len(neg) <= fpmax)
        met, short = met + good, short + (not good)
        tail = lambda a, b, a2, b2: "" if b == b2 else " · 경계 빼면 %s" % rate(a2, b2)
        print("  %s %s — 잡은 비율 %s%s · 잘못 막은 비율 %s%s → %s" % (
            area, name, rate(hit, len(pos)), tail(hit, len(pos), hit_n, len(pos_n)),
            rate(fp, len(neg)), tail(fp, len(neg), fp_n, len(neg_n)), "충족" if good else "미달"))
    sections = [
        ("놓친 것 — 막거나 가려야 했는데 통과", [r for r in rows if r["맞음"] == "X" and r["기대"] != "통과"]),
        ("잘못 막은 것 — 통과해야 했는데 막거나 가림", [r for r in rows if r["맞음"] == "X" and r["기대"] == "통과"]),
        ("오류 — 비율에서 뺌", [r for r in rows if r["결과"] == "오류"]),
    ]
    for title, rs in sections:
        if not rs:
            continue
        print("\n▶ %s (%d)" % (title, len(rs)))
        for r in rs:
            t = r["문장"] if len(r["문장"]) <= 46 else r["문장"][:46] + "…"
            extra = " · ".join(x for x in (r.get("메모", ""), r.get("상세", "") if r["결과"] == "오류" else "") if x)
            print("  %s %3s번째 줄  %s%s" % (r["영역"], r["줄"], t, "   (%s)" % extra if extra else ""))
    print("\n  판정: 충족 %d · 미달 %d (기준 — 잡은 비율 %d%% 이상 · 잘못 막은 비율 %d%% 이하)" % (met, short, detect, fpmax))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "check":
        rows = load(sys.argv[2])
        print("  묶음 %d문장 — %s" % (len(rows), " · ".join("%s %d" % (a, sum(r["영역"] == a for r in rows)) for a in AREAS)))
    elif cmd == "run" and len(sys.argv) == 5:
        if sys.argv[2] not in AREAS:
            sys.exit("영역은 4-1 ~ 4-5 가운데 하나입니다")
        run(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "summary" and len(sys.argv) == 5:
        summary(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

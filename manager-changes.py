#!/usr/bin/env python3
"""manager-changes.py — 지난 적용 뒤 Kong 에서 바뀐 것을 찾는다 (apply-config.sh 가 쓴다).

  python3 manager-changes.py <지난 적용 직후 덤프> <지금 덤프> "<POC_SWITCHES>" "<KILL_SWITCHES>" [<이번에 적용할 설정>]
  마지막 인자(deck file render 결과)를 주면 VAL 은 이번에 적용할 값과 다른 것만 낸다 — 설정 파일에 이미 옮긴 값은 유지되므로.

  두 덤프(deck gateway dump --format json)를 비교해 한 줄씩 낸다. 지난 적용 기록이 없으면 SW 의 끝 값은 -.
    SW <스위치> <지금 on/off> <지난 적용 on/off/->   /poc 플러그인 스위치 — apply-config 가 설정 파일에 적을지 정한다
    KILL <이름> <on/off>                            긴급 차단 — 지금 상태를 그대로 넘긴다
    VAL <설명>                                      그 밖에 바뀐 값 — 설정 파일 기준이라 적용하면 되돌아간다
                                                    설정 키가 있는 값이면 계속 쓰는 명령(bash set-env.sh …)을 덧붙인다
  비밀값일 수 있는 칸(이름에 key·secret·token·password·auth 등)은 값을 적지 않는다.
"""
import json
import re
import sys
import urllib.parse

SKIP = {"id", "created_at", "updated_at"}               # 비교하지 않는 칸
CHILD = {"routes", "plugins", "keyauth_credentials", "basicauth_credentials", "hmacauth_credentials",
         "jwt_secrets", "oauth2_credentials", "mtls_auth_credentials", "targets"}   # 따로 비교하는 하위 항목
UNORDERED = {("consumer", "groups"), ("consumer", "acls")}                       # 순서가 뜻이 없는 목록
SECRET = re.compile(r"secret|password|passwd|token|credential|auth|key|salt|cert", re.I)
KINDS = {"service": "서비스", "route": "경로", "consumer": "계정", "consumer_group": "그룹"}


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ref(x):
    return (x.get("name") or x.get("username") or x.get("id")) if isinstance(x, dict) else x


def entities(doc):
    """decK 파일을 (종류·이름…) → 항목 으로 편다. 플러그인은 이름·instance_name·붙은 곳으로 구분한다"""
    out = {}
    if not doc:
        return out

    def plug(p, s="", r="", c="", g=""):
        out[("plugin", p.get("name"), p.get("instance_name") or "", ref(p.get("service")) or s,
             ref(p.get("route")) or r, ref(p.get("consumer")) or c, ref(p.get("consumer_group")) or g)] = p

    def route(r):
        out[("route", r.get("name"))] = r
        for p in r.get("plugins") or []:
            plug(p, r=r.get("name"))

    for p in doc.get("plugins") or []:
        plug(p)
    for s in doc.get("services") or []:
        out[("service", s.get("name"))] = s
        for p in s.get("plugins") or []:
            plug(p, s=s.get("name"))
        for r in s.get("routes") or []:
            route(r)
    for r in doc.get("routes") or []:
        route(r)
    for c in doc.get("consumers") or []:
        out[("consumer", c.get("username"))] = c
        for p in c.get("plugins") or []:
            plug(p, c=c.get("username"))
    for g in doc.get("consumer_groups") or []:
        out[("consumer_group", g.get("name"))] = g
        for p in g.get("plugins") or []:
            plug(p, g=g.get("name"))
    return out


def label(key):
    if key[0] != "plugin":
        return "%s %s" % (KINDS.get(key[0], key[0]), key[1])
    _, name, inst, s, r, c, g = key
    scope = " · ".join(x for x in (s and "서비스 " + s, r and "경로 " + r, c and "계정 " + c, g and "그룹 " + g) if x)
    return "플러그인 %s (%s)" % (inst or name, scope or "전역")


def show(path, v):
    if any(SECRET.search(str(k)) for k in path):
        return "(값 생략)"
    if v is None:
        return "(없음)"
    t = json.dumps(v, ensure_ascii=False)
    return t if len(t) <= 60 else t[:57] + "…"


def diffs(a, b, path):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            yield from diffs(a.get(k), b.get(k), path + (k,))
    elif a != b:
        yield path, a, b


def get(obj, path):
    for k in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj


def covers(want, now):
    """적용할 값(파일에 적은 칸만 있음)이 지금 값과 같은가 — 파일에 없는 칸은 비교하지 않는다"""
    if isinstance(want, dict) and isinstance(now, dict):
        return all(covers(v, now.get(k)) for k, v in want.items())
    if isinstance(want, list) and isinstance(now, list):
        return len(want) == len(now) and all(covers(a, b) for a, b in zip(want, now))
    return want == now


def as_dump(ent):
    """적용할 설정의 서비스 url 을 덤프처럼 protocol·host·port·path 로 편다 (비교용)"""
    if not isinstance(ent, dict) or not ent.get("url"):
        return ent
    u = urllib.parse.urlparse(ent["url"])
    e = dict(ent)
    e.update(protocol=u.scheme, host=u.hostname, port=u.port or (443 if u.scheme == "https" else 80), path=u.path or None)
    return e


def hint(key, path, old, new):
    """설정 파일 키로 정하는 칸이면 그 키에 넣을 명령 — Manager 에서 바꾼 값을 계속 쓰려고 할 때"""
    if key[0] != "plugin":
        return ""
    name, route, p = key[1], key[4], ".".join(map(str, path))
    k = v = None
    if name == "rate-limiting" and route == "poc" and p in ("config.minute", "config.day"):
        k, v = {"config.minute": "DECK_RPM", "config.day": "DECK_RPD"}[p], new
    elif name == "ai-rate-limiting-advanced" and route == "poc" and p == "config.policies" and isinstance(new, list):
        lim = [l for pol in new for l in (pol.get("limits") or []) if l.get("tokens_count_strategy") == "total_tokens"]
        if len(new) == 1 and len(lim) == 1:
            k, v = "DECK_TPM", lim[0].get("limit")
    elif name == "ai-prompt-guard" and route == "poc" and p == "config.deny_patterns" and isinstance(new, list) and new \
            and isinstance(old, list) and old[:-1] == new[:-1]:     # 끝의 기밀 키워드만 바꿨을 때
        k, v = "DECK_DLP_PATTERN", new[-1]
    elif name == "ai-custom-guardrail" and route == "poc" and p == "config.response.block_message":
        k, v = "DECK_BLOCK_MESSAGE", new
    elif name == "request-size-limiting" and route == "ocr" and p == "config.allowed_payload_size":
        k, v = "DECK_OCR_MAX_MB", new
    if k is None or v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    v = str(v)
    if re.search(r"[^A-Za-z0-9._:/-]", v):
        v = "'" + v.replace("'", "'\\''") + "'"
    return " — 계속 쓰려면 bash set-env.sh %s %s" % (k, v)


def onoff(p):
    return "on" if p.get("enabled", True) else "off"


def main():
    base, now = load(sys.argv[1]), load(sys.argv[2])
    if now is None:
        sys.exit(2)
    B, N = entities(base), entities(now)
    W = entities(load(sys.argv[5])) if len(sys.argv) > 5 else None
    if not N:          # 빈 DB(처음 적용) — 지난 기록과 비교하지 않는다
        B = {}
    done = set()       # 스위치·긴급 차단의 enabled 는 VAL 에서 뺀다
    for spec in sys.argv[3].split():
        name, _default, pname = spec.split(":")
        key = ("plugin", pname, "", "", "poc", "", "")
        if key in N:
            print("SW", name, onoff(N[key]), onoff(B[key]) if key in B else "-")
            done.add(key)
    for n in sys.argv[4].split():
        for key, p in N.items():
            if key[0] == "plugin" and key[2] == "kill-switch--" + n:
                print("KILL", n, onoff(p))
                done.add(key)
    for key in sorted(set(B) & set(N), key=str):
        b, n = B[key], N[key]
        for f in sorted(set(b) | set(n)):
            if f in SKIP or f in CHILD or (f == "enabled" and key in done):
                continue
            bv, nv = b.get(f), n.get(f)
            if (key[0], f) in UNORDERED:
                bv, nv = [sorted(x or [], key=lambda i: json.dumps(i, sort_keys=True)) for x in (bv, nv)]
            for path, x, y in diffs(bv, nv, (f,)):
                if W is not None and key in W and covers(get(as_dump(W[key]), path), y):
                    continue            # 설정 파일에 이미 같은 값 — 적용해도 유지된다
                print("VAL", "%s %s: %s → %s%s" % (label(key), ".".join(map(str, path)), show(path, x), show(path, y), hint(key, path, x, y)))
    for key in sorted(set(B) - set(N), key=str):
        print("VAL", "%s: 지워져 있음 → 설정 파일대로 다시 만듦" % label(key))


if __name__ == "__main__":
    main()

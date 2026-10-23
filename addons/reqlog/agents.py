#!/usr/bin/env python3
"""agents.py — 등록된 AI 에이전트 목록을 요청 기록 DB(reqlog)의 agents 표로 옮긴다 → Grafana 「에이전트 목록」이 보여 준다.

에이전트 = 이름이 agent- 로 시작하는 Kong 경로(Route) — Grafana 의 다른 에이전트 패널과 같은 기준.
Kong Manager 로 등록한 것(태그 없음)과 설정 파일(kong-poc 태그)로 등록한 것을 모두 읽는다. 워크스페이스마다 읽는다.

읽는 것 (Admin API — 읽기만)
  경로 · Gateway Service · Upstream(상태 점검 결과 · Target) · 경로에 붙은 플러그인(인증 · ACL · AI A2A Proxy · 긴급 차단)
  부를 수 있는 계정 — ACL 허용 목록이면 그 그룹의 계정(계정의 ACL 칸 · include_consumer_groups 면 Consumer Group 구성원까지)
  Agent Card — AI A2A Proxy 를 붙인 경로만, 에이전트 서버(Target)에서 바로 /.well-known/agent-card.json 을 읽음
    (Kong 을 거치지 않으므로 키가 필요 없다. HTTPS 인증서 검사는 그 Upstream 상태 점검 설정(https_verify_certificate)을 따른다)

  python3 agents.py          한 번 읽어 DB 에 넣고 끝 (--print 면 넣지 않고 보여 주기만)
  reqlog.py --loop 가 1분마다 부른다 (ADMIN_PORT · KONG_ADMIN_PASSWORD 가 있을 때만)

환경변수: ADMIN_PORT · KONG_ADMIN_PASSWORD (RBAC 토큰) · reqlog.py 와 같은 PG 설정(PG_BIN · PG_PORT · RUN_DIR)
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ADMIN = "http://127.0.0.1:%s" % (os.environ.get("ADMIN_PORT") or "8001")
TOKEN = os.environ.get("KONG_ADMIN_PASSWORD") or ""
CARD_TIMEOUT = 3
AUTH_PLUGINS = {"key-auth": "Key Auth", "key-auth-enc": "Key Auth", "openid-connect": "OIDC(SSO)", "jwt": "JWT", "basic-auth": "Basic Auth",
                "hmac-auth": "HMAC", "oauth2": "OAuth2", "oauth2-introspection": "OAuth2", "ldap-auth": "LDAP", "ldap-auth-advanced": "LDAP",
                "mtls-auth": "mTLS"}
COLS = ("workspace", "name", "paths", "kind", "registered_by", "auth", "access_rule", "callers", "kill_switch",
        "a2a_logging", "health", "targets", "card_name", "card_description", "card_version", "card_skills", "card_error")


def admin(path):
    req = urllib.request.Request(ADMIN + path, headers={"Kong-Admin-Token": TOKEN} if TOKEN else {})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


def all_of(path):
    """페이지를 넘겨 가며 data 를 모두"""
    out, nxt = [], path + ("&" if "?" in path else "?") + "size=1000"
    while nxt:
        d = admin(nxt)
        out += d.get("data") or []
        nxt = d.get("next")
        if nxt and nxt.startswith("http"):
            nxt = urllib.parse.urlsplit(nxt)._replace(scheme="", netloc="").geturl()
    return out


def ref_id(x):
    return (x or {}).get("id") if isinstance(x, dict) else None


def card_of(url, verify):
    """에이전트 서버에서 Agent Card 를 읽음 → (카드, 오류 글)"""
    ctx = None
    if url.startswith("https://") and not verify:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    last = None
    for suffix in ("/.well-known/agent-card.json", "/.well-known/agent.json"):   # A2A 0.3 · 0.2
        try:
            with urllib.request.urlopen(urllib.request.Request(url.rstrip("/") + suffix, headers={"Accept": "application/json"}),
                                        timeout=CARD_TIMEOUT, context=ctx) as r:
                d = json.loads(r.read(1024 * 1024).decode("utf-8", "replace"))
                if isinstance(d, dict):
                    return d, None
                last = "Agent Card 형식 오류(JSON 객체 아님)"
        except urllib.error.HTTPError as e:
            last = "HTTP %d" % e.code
        except Exception as e:  # 연결 거부 · 시간 초과 · 인증서 · JSON 아님
            last = type(e).__name__ + ": " + str(e)[:120]
    return None, last


def access_rule(acl):
    """ACL 설정 → 사람이 읽는 규칙 글"""
    if not acl:
        return None
    c = acl.get("config") or {}
    off = "" if acl.get("enabled", True) else " (ACL 비활성)"
    if c.get("allow"):
        return "허용 그룹: %s%s%s" % (", ".join(c["allow"]), " (Consumer Group 포함)" if c.get("include_consumer_groups") else "", off)
    if c.get("deny"):
        return "거부 그룹: %s%s%s" % (", ".join(c["deny"]), " (Consumer Group 포함)" if c.get("include_consumer_groups") else "", off)
    if c.get("allow_when"):
        return "허용 식: %s%s" % (" OR ".join(c["allow_when"]), off)
    if c.get("deny_when"):
        return "거부 식: %s%s" % (" OR ".join(c["deny_when"]), off)
    return "ACL 미적용" + off


def collect_ws(ws):
    p = "/" + urllib.parse.quote(ws)
    routes = [r for r in all_of(p + "/routes") if (r.get("name") or "").startswith("agent-")]
    if not routes:
        return []
    services = {s["id"]: s for s in all_of(p + "/services")}
    upstreams = {u["name"]: u for u in all_of(p + "/upstreams")}
    plugins = all_of(p + "/plugins")
    consumers = {c["id"]: c["username"] or c.get("custom_id") or c["id"] for c in all_of(p + "/consumers")}
    acl_tags = {}                                   # 그룹 이름 → 계정 (계정의 ACL 칸)
    for a in all_of(p + "/acls"):
        acl_tags.setdefault(a.get("group"), set()).add(consumers.get(ref_id(a.get("consumer")), "?"))
    groups = {}                                     # Consumer Group 이름 → 구성원
    for g in all_of(p + "/consumer_groups"):
        try:
            d = admin("%s/consumer_groups/%s/consumers" % (p, g["id"]))
            mem = d.get("data") or d.get("consumers") or []
        except Exception:
            mem = []
        groups[g["name"]] = {m.get("username") or m.get("id") for m in mem if isinstance(m, dict)}
    rows = []
    for r in routes:
        on_route = [x for x in plugins if ref_id(x.get("route")) == r["id"]]
        svc = services.get(ref_id(r.get("service"))) or {}
        # 같은 이름이 경로 · 서비스 · 전역에 함께 있으면 가장 좁은 것(경로)이 돈다 — 경로 것을 먼저 본다
        svc_plugins = [x for x in plugins if ref_id(x.get("service")) == svc.get("id") and not x.get("route") and not x.get("consumer")]
        pick = lambda name: next((x for x in on_route if x["name"] == name), None) or next((x for x in svc_plugins if x["name"] == name), None)
        auths = sorted({AUTH_PLUGINS[x["name"]] for x in on_route + svc_plugins if x["name"] in AUTH_PLUGINS and x.get("enabled", True)})
        acl, a2a, kills = pick("acl"), pick("ai-a2a-proxy"), [x for x in on_route if x["name"] == "request-termination"]
        rule = access_rule(acl)
        callers = None
        if acl and acl.get("enabled", True):
            c = acl.get("config") or {}
            if c.get("allow"):
                who = set()
                for g in c["allow"]:
                    who |= acl_tags.get(g, set())
                    if c.get("include_consumer_groups"):
                        who |= groups.get(g, set())
                callers = ", ".join(sorted(who)) or "(그룹 구성원 없음)"
            elif c.get("deny"):
                callers = "거부 그룹 외 인증된 Consumer 전체"
            else:
                callers = "접근 정책(식) 참조"
        elif auths:
            sso = pick("openid-connect")          # SSO 만 있고 사용자를 Consumer 로 매핑하지 않으면 Consumer 가 없다
            only_sso = auths == ["OIDC(SSO)"] and sso is not None and not (sso.get("config") or {}).get("consumer_claim")
            callers = "SSO 인증 사용자(Consumer 매핑 없음)" if only_sso else "인증된 Consumer 전체"
        else:
            callers = "제한 없음(인증 미적용)"
        if not rule:
            rule = "제한 없음(인증만 적용)" if auths else "⚠ 공개(인증 · ACL 미적용)"
        # 서버 · 상태 — 서비스 host 가 Upstream 이름이면 그 Target 과 상태 점검 결과
        up = upstreams.get(svc.get("host") or "")
        health, targets, verify, bases = "헬스 체크 없음(Upstream 미사용)", "", True, []
        if up:
            hc = ((up.get("healthchecks") or {}).get("active") or {})
            verify = hc.get("https_verify_certificate", True)
            try:
                h = admin("%s/upstreams/%s/health" % (p, up["id"])).get("data") or []
            except Exception:
                h = []
            states = [t.get("health") for t in h]
            targets = ", ".join(t.get("target") for t in h if t.get("target"))
            if not states:
                health = "Target 없음"
            elif all(s == "HEALTHY" for s in states):
                health = "정상"
            elif all(s == "HEALTHCHECKS_OFF" for s in states):
                health = "헬스 체크 꺼짐"
            elif any(s == "HEALTHY" for s in states):
                health = "일부 장애(%d/%d 정상)" % (states.count("HEALTHY"), len(states))
            else:
                health = "장애" if any(s == "UNHEALTHY" for s in states) else ("DNS 오류" if any(s == "DNS_ERROR" for s in states) else " · ".join(sorted(set(states))))
            bases = ["%s://%s%s" % (svc.get("protocol") or "http", t.get("target"), svc.get("path") or "") for t in h if t.get("target")]
        elif svc.get("host"):
            targets = "%s:%s" % (svc["host"], svc.get("port") or "")
            bases = ["%s://%s:%s%s" % (svc.get("protocol") or "http", svc["host"], svc.get("port") or 80, svc.get("path") or "")]
        card, cerr = (None, None)
        if a2a and a2a.get("enabled", True) and bases:
            card, cerr = card_of(bases[0], verify)
        lg = ((a2a or {}).get("config") or {}).get("logging") or {}
        skills = (card or {}).get("skills") if isinstance((card or {}).get("skills"), list) else []
        rows.append({
            "workspace": ws, "name": r["name"], "paths": ", ".join(r.get("paths") or []) or None,
            "kind": "A2A" if a2a and a2a.get("enabled", True) else "HTTP",
            "registered_by": "설정 파일(decK)" if "kong-poc" in (r.get("tags") or []) else "Kong Manager",
            "auth": " + ".join(auths) if auths else "미적용",
            "access_rule": rule, "callers": callers,
            "kill_switch": any(k.get("enabled", True) for k in kills),
            "a2a_logging": None if not a2a else ("통계" if lg.get("log_statistics") else "통계 비활성") + (" · 본문" if lg.get("log_payloads") else ""),
            "health": health, "targets": targets or None,
            "card_name": (card or {}).get("name"), "card_description": (card or {}).get("description"),
            "card_version": (card or {}).get("version") or (card or {}).get("protocolVersion"),
            "card_skills": ", ".join(s.get("name") or s.get("id") or "?" for s in skills if isinstance(s, dict)) or None,
            "card_error": cerr if a2a and not card else None,
        })
    return rows


def collect():
    try:
        wss = [w["name"] for w in all_of("/workspaces")]
    except Exception:
        wss = ["default"]
    rows = []
    for ws in wss:
        rows += collect_ws(ws)
    return rows


def lit(v):
    if v is None or v == "":
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    return "'" + str(v).replace("\x00", "").replace("'", "''") + "'"


def replace_sql(rows):
    out = ["BEGIN;", "DELETE FROM agents;"]
    for r in rows:
        out.append("INSERT INTO agents (%s, updated_at) VALUES (%s, now());" % (", ".join(COLS), ", ".join(lit(r[c]) for c in COLS)))
    out.append("COMMIT;")
    return "\n".join(out).encode("utf-8")


def main():
    rows = collect()
    if "--print" in sys.argv:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from reqlog import psql
    psql(replace_sql(rows))
    print("에이전트 %d개" % len(rows))


if __name__ == "__main__":
    main()

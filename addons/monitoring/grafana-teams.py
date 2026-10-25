#!/usr/bin/env python3
"""grafana-teams.py — 팀 Grafana: 팀마다 조직 · 보기 전용 계정 · 그 워크스페이스로 거른 대시보드를 맞춘다 (start.sh 가 부른다).

입력(표준 입력, 한 줄 = 한 팀, 탭으로 나눔): 이름 · 워크스페이스 · 요청 기록 DB 계정 · 그 비밀번호 · 로그인 비밀번호
환경변수: GRAFANA_URL(…/grafana) · GRAFANA_ADMIN_PASSWORD · PROM_PORT · PG_PORT · KONG_POC_DASHBOARDS(start.sh 가 준비한 대시보드 폴더)

  조직 이름 = 팀 이름, 로그인 = 팀 이름 — 그 조직의 Viewer 로만 둔다 (다른 조직에 들어 있으면 뺀다)
  데이터 원본: Prometheus(기존과 같은 것) · 요청 기록(그 워크스페이스 행만 읽히는 DB 계정 — reqlog/schema.sql 의 행 단위 제한)
  대시보드: 기존 대시보드를 같은 uid 로 — 지표 쿼리마다 workspace="<워크스페이스>" 를 붙인다. 요청 기록은 DB 가 거른다
    Upstream 상태 지표(kong_upstream_target_health)는 workspace 라벨이 없어 거를 수 없으므로 그 패널 · 변수는 팀 화면에서 뺀다
    (다른 워크스페이스의 에이전트 이름 · 상태가 보이지 않게 — 팀 화면의 에이전트 상태는 에이전트 목록의 상태 열, DB 가 거름)
  지표 저장소(Prometheus)는 사용자별로 막지 못한다 → 팀 계정은 보기 전용(화면에서 쿼리를 고치거나 새로 쓰지 못함)
Grafana 기록은 로컬 디스크라 새 환경이 뜨면 비어 있다 — 뜰 때마다 다시 맞춘다 (여러 번 돌려도 같음).
"""
import base64
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

G = os.environ["GRAFANA_URL"].rstrip("/")
AUTH = "Basic " + base64.b64encode(("admin:" + os.environ["GRAFANA_ADMIN_PASSWORD"]).encode()).decode()
DASH = pathlib.Path(os.environ.get("KONG_POC_DASHBOARDS") or "/nonexistent")
PROM_URL = "http://127.0.0.1:%s" % os.environ.get("PROM_PORT", "9090")
PG_ADDR = "127.0.0.1:%s" % os.environ.get("PG_PORT", "5432")
FOLDER_UID, FOLDER_TITLE = "kong-poc", "Kong AI Gateway PoC"
HOME_UID = "kong-ai-gateway-poc"


def api(method, path, body=None, org=None):
    req = urllib.request.Request(G + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", AUTH)
    req.add_header("Content-Type", "application/json")
    if org:
        req.add_header("X-Grafana-Org-Id", str(org))
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, {"message": raw[:200].decode("utf-8", "replace")}


def need(st, d, what):
    if st != 200:
        raise RuntimeError("%s 실패 (%s %s)" % (what, st, (d or {}).get("message", d)))
    return d


# 지표 쿼리에 워크스페이스를 붙인다 — workspace 라벨이 있는 지표(요청 · 지연 · 대역폭 · AI)만 {workspace="…"} (이미 { 가 있으면 그 안 맨 앞에).
#   노드 전체 지표(연결 수 · 메모리 · 라이선스 · DB 등)는 라벨이 없어 그대로 둔다 — 붙이면 빈 그래프가 된다 (Kong 3.16 /metrics 실측)
METRIC = re.compile(r"\b(kong_(?:http_requests_total|bandwidth_bytes|(?:kong|request|upstream|kong_internal)_latency_ms"
                    r"(?:_bucket|_sum|_count)?|ai_[A-Za-z0-9_]+))\b(\{\s*\}|\{)?")


def scope(expr, ws):
    lab = 'workspace="%s"' % ws

    def rep(m):
        b = m.group(2)
        if b is None or b.strip() != "{":   # 중괄호 없음 · 빈 중괄호
            return m.group(1) + "{" + lab + "}"
        return m.group(1) + "{" + lab + ","
    return METRIC.sub(rep, expr)


# workspace 라벨이 없어 팀별로 거를 수 없는 지표 — 이 지표를 쓰는 패널 · 변수는 팀 화면에서 뺀다
UNSCOPED = re.compile(r"\bkong_upstream_target_health\b")


def drop_unscoped(d):
    """Upstream 상태 지표를 쓰는 패널(접힌 줄 안 포함) · 변수를 뺀다. 남는 패널은 Grafana 가 위로 당겨 빈자리를 메운다"""
    def uses(p):
        return any(UNSCOPED.search(t.get("expr") or "") for t in p.get("targets") or [] if isinstance(t, dict))

    def prune(panels):
        out = []
        for p in panels:
            if isinstance(p.get("panels"), list) and p["panels"]:
                p["panels"] = prune(p["panels"])
                if not p["panels"]:
                    continue                      # 접힌 줄 안의 패널이 모두 빠지면 빈 줄도 뺀다
            if not uses(p):
                out.append(p)
        return out
    d["panels"] = prune(d.get("panels") or [])
    tl = (d.get("templating") or {}).get("list")
    if isinstance(tl, list):
        d["templating"]["list"] = [v for v in tl if not UNSCOPED.search("%s %s" % (v.get("query") or "", v.get("definition") or ""))]


def walk(o, ws):
    """패널 쿼리(expr) · 변수 쿼리(query · definition 의 kong_ 지표)에 워크스페이스를 붙인다. 요청 기록 SQL(rawSql)은 그대로"""
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == "expr" and isinstance(v, str):
                o[k] = scope(v, ws)
            elif k in ("query", "definition") and isinstance(v, str) and "kong_" in v:
                o[k] = scope(v, ws)
            else:
                walk(v, ws)
    elif isinstance(o, list):
        for v in o:
            walk(v, ws)


def ensure_org(name):
    st, d = api("GET", "/api/orgs/name/" + urllib.parse.quote(name))
    if st == 200:
        return d["id"]
    return need(*api("POST", "/api/orgs", {"name": name}), "조직 %s 만들기" % name)["orgId"]


def ensure_ds(org, body):
    st, _ = api("GET", "/api/datasources/uid/" + body["uid"], org=org)
    if st == 200:
        need(*api("PUT", "/api/datasources/uid/" + body["uid"], body, org=org), "데이터 원본 %s 고치기" % body["name"])
    else:
        need(*api("POST", "/api/datasources", body, org=org), "데이터 원본 %s 만들기" % body["name"])


def ensure_folder(org):
    st, _ = api("GET", "/api/folders/" + FOLDER_UID, org=org)
    if st != 200:
        need(*api("POST", "/api/folders", {"uid": FOLDER_UID, "title": FOLDER_TITLE}, org=org), "폴더 만들기")


def put_dashboards(org, ws):
    files = sorted(DASH.glob("*.json"))
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        d.pop("id", None)
        d.pop("version", None)
        drop_unscoped(d)
        walk(d, ws)
        d["title"] = "%s (워크스페이스 %s)" % (d.get("title") or f.stem, ws)
        need(*api("POST", "/api/dashboards/db", {"dashboard": d, "folderUid": FOLDER_UID, "overwrite": True,
                                                 "message": "kong-poc 팀 화면 — 워크스페이스 " + ws}, org=org),
             "대시보드 %s 넣기" % f.name)
    if files:
        api("PUT", "/api/org/preferences", {"homeDashboardUID": HOME_UID}, org=org)
    return len(files)


def ensure_user(org, login, pw):
    st, d = api("GET", "/api/users/lookup?loginOrEmail=" + urllib.parse.quote(login))
    if st == 200:
        uid = d["id"]
        need(*api("PUT", "/api/admin/users/%d/password" % uid, {"password": pw}), "계정 %s 비밀번호" % login)
        st, d2 = api("POST", "/api/orgs/%d/users" % org, {"loginOrEmail": login, "role": "Viewer"})
        if st not in (200, 409):
            need(st, d2, "계정 %s 조직에 넣기" % login)
        api("PATCH", "/api/orgs/%d/users/%d" % (org, uid), {"role": "Viewer"})
    else:
        uid = need(*api("POST", "/api/admin/users", {"name": login, "login": login, "password": pw, "OrgId": org}),
                   "계정 %s 만들기" % login)["id"]
    api("PUT", "/api/admin/users/%d/permissions" % uid, {"isGrafanaAdmin": False})
    st, orgs = api("GET", "/api/users/%d/orgs" % uid)
    for o in (orgs if st == 200 and isinstance(orgs, list) else []):
        if o.get("orgId") != org:          # 기존 조직(전체 화면)에 들어 있으면 뺀다
            api("DELETE", "/api/orgs/%d/users/%d" % (o["orgId"], uid))
    st, orgs = api("GET", "/api/users/%d/orgs" % uid)
    return [(o.get("name"), o.get("role")) for o in (orgs if isinstance(orgs, list) else [])]


def main():
    teams = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
    if not DASH.is_dir():
        print("  ⚠ 대시보드 폴더가 없어 대시보드는 건너뜀: %s" % DASH)
    bad = 0
    for t in teams:
        if len(t) != 5:
            continue
        name, ws, dbrole, dbpw, pw = t
        try:
            org = ensure_org(name)
            ensure_ds(org, {"name": "Prometheus", "uid": "kong-poc-prometheus", "type": "prometheus", "access": "proxy",
                            "url": PROM_URL, "isDefault": True})
            ensure_ds(org, {"name": "요청 기록", "uid": "kong-poc-reqlog", "type": "grafana-postgresql-datasource",
                            "access": "proxy", "url": PG_ADDR, "user": dbrole,
                            "jsonData": {"database": "reqlog", "sslmode": "disable", "postgresVersion": 1400,
                                         "timescaledb": False, "maxOpenConns": 5},
                            "secureJsonData": {"password": dbpw}})
            ensure_folder(org)
            n = put_dashboards(org, ws) if DASH.is_dir() else 0
            member = ensure_user(org, name, pw)
            print("  팀 %s — 워크스페이스 %s · 조직 %d · 대시보드 %d개 · 로그인 %s (%s)"
                  % (name, ws, org, n, name, ", ".join("%s %s" % m for m in member)))
        except RuntimeError as e:
            bad += 1
            print("  ⚠ 팀 %s: %s" % (name, e))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

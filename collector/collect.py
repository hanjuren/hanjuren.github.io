#!/usr/bin/env python3
"""서울/경기 공공임대 청약 공고 수집기.

마이홈포털 + LH청약플러스 API에서 공고를 수집해 data/notices.json으로 저장한다.
표준 라이브러리만 사용 (의존성 없음).
"""
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGIONS = {"11": "서울특별시", "41": "경기도"}
# LH 상위유형 중 주택이 아닌 것 (상가/토지 등)은 제외
LH_EXCLUDE_UPP = {"01", "22", "02"}  # 토지, 상가, 기타


def load_key() -> str:
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith("DATA_GO_KR_KEY="):
            return line.split("=", 1)[1].strip()
    sys.exit(".env에 DATA_GO_KR_KEY가 없습니다")


def get_json(url: str, params: dict, retries: int = 3):
    qs = urllib.parse.urlencode(params)
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(f"{url}?{qs}", timeout=15) as res:
                body = res.read().decode("utf-8")
            if body.strip() in ("Unauthorized", "API not found"):
                raise RuntimeError(body.strip())
            return json.loads(body)
        except Exception as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def norm_date(raw: str) -> str:
    """'20260713' | '2026.07.13' → '2026-07-13' (없으면 '')"""
    digits = re.sub(r"\D", "", raw or "")
    if len(digits) != 8:
        return ""
    return f"{digits[:4]}-{digits[4:6]}-{digits[6:]}"


# ── 마이홈포털 ──────────────────────────────────────────────

def fetch_myhome(key: str) -> list[dict]:
    url = "http://apis.data.go.kr/1613000/HWSPR02/rsdtRcritNtcList"
    notices: dict[str, dict] = {}
    for brtc, region in REGIONS.items():
        page = 1
        while True:
            body = get_json(url, {
                "serviceKey": key, "numOfRows": 100, "pageNo": page, "brtcCode": brtc,
            })["response"]["body"]
            items = body.get("item") or []
            if isinstance(items, dict):
                items = [items]
            for it in items:
                nid = f"myhome-{it['pblancId']}"
                n = notices.setdefault(nid, {
                    "id": nid,
                    "source": "마이홈",
                    "title": it.get("pblancNm", ""),
                    "status": it.get("sttusNm", ""),
                    "institution": it.get("suplyInsttNm", ""),
                    "supplyType": it.get("suplyTyNm", ""),
                    "houseType": it.get("houseTyNm", ""),
                    "region": region,
                    "dates": {
                        "notice": norm_date(it.get("rcritPblancDe", "")),
                        "applyStart": norm_date(it.get("beginDe", "")),
                        "applyEnd": norm_date(it.get("endDe", "")),
                        "winner": norm_date(it.get("przwnerPresnatnDe", "")),
                    },
                    "url": it.get("pcUrl") or it.get("url", ""),
                    "lhPanId": extract_pan_id(it.get("url", "")),
                    "complexes": [],
                })
                addr = it.get("fullAdres") or ""
                sigungu = it.get("signguNm") or ""
                complex_ = {
                    "name": it.get("hsmpNm", ""),
                    "address": addr,
                    "sigungu": sigungu,
                    "households": it.get("totHshldCo") or 0,
                    "deposit": it.get("rentGtn") or 0,
                    "monthlyRent": it.get("mtRntchrg") or 0,
                }
                if complex_ not in n["complexes"]:
                    n["complexes"].append(complex_)
            total = int(body.get("totalCount") or 0)
            if page * 100 >= total or not items:
                break
            page += 1
    return list(notices.values())


def extract_pan_id(url: str) -> str:
    m = re.search(r"panId=([A-Za-z0-9-]+)", url or "")
    return m.group(1) if m else ""


# ── LH청약플러스 ─────────────────────────────────────────────

def fetch_lh(key: str) -> list[dict]:
    list_url = "http://apis.data.go.kr/B552555/lhLeaseNoticeInfo1/lhLeaseNoticeInfo1"
    notices = []
    for cnp, region in REGIONS.items():
        page = 1
        while True:
            data = get_json(list_url, {
                "serviceKey": key, "PG_SZ": 100, "PAGE": page, "CNP_CD": cnp,
            })
            rows = next((d["dsList"] for d in data if "dsList" in d), [])
            for row in rows:
                if row.get("UPP_AIS_TP_CD") in LH_EXCLUDE_UPP:
                    continue
                notices.append({
                    "id": f"lh-{row['PAN_ID']}",
                    "source": "LH",
                    "title": row.get("PAN_NM", ""),
                    "status": row.get("PAN_SS", ""),
                    "institution": "LH",
                    "supplyType": row.get("AIS_TP_CD_NM", ""),
                    "houseType": row.get("UPP_AIS_TP_NM", ""),
                    "region": region,
                    "dates": {
                        "notice": norm_date(row.get("PAN_NT_ST_DT", "")),
                        "close": norm_date(row.get("CLSG_DT", "")),
                    },
                    "url": row.get("DTL_URL", ""),
                    "lhPanId": row.get("PAN_ID", ""),
                    "complexes": [],
                    "_detail_params": {
                        "PAN_ID": row.get("PAN_ID", ""),
                        "SPL_INF_TP_CD": row.get("SPL_INF_TP_CD", ""),
                        "CCR_CNNT_SYS_DS_CD": row.get("CCR_CNNT_SYS_DS_CD", ""),
                        "UPP_AIS_TP_CD": row.get("UPP_AIS_TP_CD", ""),
                        "AIS_TP_CD": row.get("AIS_TP_CD", ""),
                    },
                })
            all_cnt = int(rows[0]["ALL_CNT"]) if rows else 0
            if page * 100 >= all_cnt or not rows:
                break
            page += 1
    return notices


def enrich_lh_detail(key: str, notice: dict) -> None:
    """LH 상세 API에서 일정/단지 정보 보강."""
    url = "http://apis.data.go.kr/B552555/lhLeaseNoticeDtlInfo1/getLeaseNoticeDtlInfo1"
    params = {"serviceKey": key, **notice.pop("_detail_params")}
    try:
        data = get_json(url, params)
    except Exception as e:
        print(f"  ! 상세 조회 실패 {notice['id']}: {e}", file=sys.stderr)
        return
    block = next((d for d in data if "dsSplScdl" in d or "dsSbd" in d), {})
    scdl = (block.get("dsSplScdl") or [{}])[0]
    notice["dates"].update({k: v for k, v in {
        "applyStart": norm_date(scdl.get("SBSC_ACP_ST_DT", "")),
        "applyEnd": norm_date(scdl.get("SBSC_ACP_CLSG_DT", "")),
        "docStart": norm_date(scdl.get("PPR_ACP_ST_DT", "")),
        "docEnd": norm_date(scdl.get("PPR_ACP_CLSG_DT", "")),
        "winner": norm_date(scdl.get("PZWR_ANC_DT", "")),
        "contractStart": norm_date(scdl.get("CTRT_ST_DT", "")),
        "contractEnd": norm_date(scdl.get("CTRT_ED_DT", "")),
    }.items() if v})
    for sbd in block.get("dsSbd") or []:
        notice["complexes"].append({
            "name": sbd.get("LCC_NT_NM", ""),
            "address": " ".join(x for x in [sbd.get("LGDN_ADR", ""), sbd.get("LGDN_DTL_ADR", "")] if x),
            "households": sbd.get("HSH_CNT", ""),
            "area": sbd.get("DDO_AR", ""),
            "moveIn": sbd.get("MVIN_XPC_YM", ""),
        })


def dedupe_corrections(notices: list[dict]) -> list[dict]:
    """'[정정공고]' 접두어를 벗긴 제목이 같으면 공고일이 가장 최신인 것만 남긴다."""
    def base_title(title: str) -> str:
        while title.startswith("[정정공고]"):
            title = title[len("[정정공고]"):]
        return title.strip()

    groups: dict[tuple, dict] = {}
    for n in notices:
        key = (n["source"], n["region"], base_title(n["title"]))
        cur = groups.get(key)
        if not cur or n["dates"].get("notice", "") > cur["dates"].get("notice", ""):
            groups[key] = n
    return list(groups.values())


# ── 메인 ────────────────────────────────────────────────────

def main() -> None:
    key = load_key()

    print("마이홈포털 수집 중...")
    myhome = fetch_myhome(key)
    print(f"  → {len(myhome)}건")

    print("LH청약플러스 수집 중...")
    lh = fetch_lh(key)
    print(f"  → {len(lh)}건 (주택 공고만)")

    print("LH 상세 일정 보강 중...")
    for n in lh:
        enrich_lh_detail(key, n)
        time.sleep(0.2)  # 트래픽 예의

    # 중복 제거: 마이홈 공고가 LH 공고를 가리키면 LH 쪽(일정이 더 상세)을 남긴다
    lh_pan_ids = {n["lhPanId"] for n in lh}
    merged = lh + [n for n in myhome if n["lhPanId"] not in lh_pan_ids]

    # 정정공고가 있으면 원공고는 대체된 것 → 같은 제목 그룹에서 최신 공고만 남긴다
    merged = dedupe_corrections(merged)
    for n in merged:
        n.pop("lhPanId", None)
        n.pop("_detail_params", None)

    out = {
        "updatedAt": date.today().isoformat(),
        "regions": list(REGIONS.values()),
        "count": len(merged),
        "notices": sorted(merged, key=lambda n: n["dates"].get("notice", ""), reverse=True),
    }
    out_path = ROOT / "data" / "notices.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)  # 빈 data/는 git 미추적이라 없을 수 있음
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    # 웹 UI가 file://로도 열리게 JS 래핑본도 생성
    (ROOT / "web" / "data.js").write_text(
        "window.NOTICES = " + json.dumps(out, ensure_ascii=False) + ";")
    print(f"완료: {len(merged)}건 → {out_path}")


if __name__ == "__main__":
    main()

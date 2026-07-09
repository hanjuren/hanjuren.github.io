import Foundation

/// collector/collect.py의 Swift 포팅.
/// 마이홈포털 + LH청약플러스 API에서 서울/경기 공공임대 공고를 수집한다.
enum DataFetcher {
    static let apiKey = Secrets.dataGoKrKey   // 빌드 시 .env에서 생성 (Secrets.swift, git 제외)
    static let regions: [(code: String, name: String)] = [("11", "서울특별시"), ("41", "경기도")]
    static let lhExcludeUpp: Set<String> = ["01", "22", "02"]  // 토지, 상가, 기타

    static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CheongyakCal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notices.json")
    }

    static func log(_ message: String) {
        let dir = cacheURL.deletingLastPathComponent()
        let logURL = dir.appendingPathComponent("fetch.log")
        let fmt = ISO8601DateFormatter()
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func loadCache() -> [String: Any]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - 공고 최초 발견일 레지스트리 (NEW 배지용)

    private static var seenURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("first-seen.json")
    }

    /// 이번 수집의 공고ID들을 레지스트리에 반영하고,
    /// 최근 3일 내 최초 발견된 공고의 {id: 발견일} 맵을 돌려준다.
    /// 첫 수집(레지스트리 없음)은 baseline으로 기록하고 NEW 없이 반환.
    private static func trackFirstSeen(ids: [String], today: String) -> [String: String] {
        var baseline = today
        var seen: [String: String] = [:]
        if let data = try? Data(contentsOf: seenURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            baseline = obj["baseline"] as? String ?? today
            seen = obj["seen"] as? [String: String] ?? [:]
        }
        for id in ids where seen[id] == nil {
            seen[id] = today
        }
        let out: [String: Any] = ["baseline": baseline, "seen": seen]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            try? data.write(to: seenURL)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cutoff = fmt.string(from: Date().addingTimeInterval(-3 * 86400))
        return seen.filter { id, date in
            ids.contains(id) && date > cutoff && date != baseline
        }
    }

    // MARK: - 수집 파이프라인

    static func refresh() async throws -> [String: Any] {
        log("수집 시작")
        let myhome = try await fetchMyhome()
        log("마이홈 \(myhome.count)건")
        var lh = try await fetchLHList()
        log("LH 목록 \(lh.count)건, 상세 보강 시작")
        lh = await enrichAll(lh)
        log("상세 보강 완료")

        // 마이홈 공고가 LH 공고를 가리키면 LH 쪽(일정 상세)을 남긴다
        let lhPanIds = Set(lh.compactMap { $0["lhPanId"] as? String })
        var merged = lh + myhome.filter { !lhPanIds.contains(($0["lhPanId"] as? String) ?? "") }
        merged = dedupeCorrections(merged)
        for i in merged.indices {
            merged[i].removeValue(forKey: "lhPanId")
            merged[i].removeValue(forKey: "_detailParams")
        }
        merged.sort {
            let a = (($0["dates"] as? [String: String])?["notice"]) ?? ""
            let b = (($1["dates"] as? [String: String])?["notice"]) ?? ""
            return a > b
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let ids = merged.compactMap { $0["id"] as? String }
        let recentNew = trackFirstSeen(ids: ids, today: today)
        let out: [String: Any] = [
            "updatedAt": today,
            "lastUpdatedAt": ISO8601DateFormatter().string(from: Date()),
            "recentNew": recentNew,
            "regions": regions.map(\.name),
            "count": merged.count,
            "notices": merged,
        ]
        let data = try JSONSerialization.data(withJSONObject: out)
        try data.write(to: cacheURL)
        log("완료: \(merged.count)건 저장")
        return out
    }

    // MARK: - HTTP

    private static func getJSON(_ urlString: String, retries: Int = 3) async throws -> Any {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<retries {
            do {
                guard let url = URL(string: urlString) else { throw URLError(.badURL) }
                let (data, _) = try await URLSession.shared.data(from: url)
                if let body = String(data: data, encoding: .utf8),
                   body == "Unauthorized" || body == "API not found" {
                    throw NSError(domain: "DataFetcher", code: 401,
                                  userInfo: [NSLocalizedDescriptionKey: body])
                }
                return try JSONSerialization.jsonObject(with: data)
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * (attempt + 1)))
            }
        }
        throw lastError
    }

    private static func normDate(_ raw: String?) -> String {
        let digits = (raw ?? "").filter(\.isNumber)
        guard digits.count == 8 else { return "" }
        let s = Array(digits)
        return "\(String(s[0..<4]))-\(String(s[4..<6]))-\(String(s[6..<8]))"
    }

    private static func extractPanId(_ url: String?) -> String {
        guard let url, let range = url.range(of: "panId=") else { return "" }
        return String(url[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }))
    }

    // MARK: - 마이홈포털

    private static func fetchMyhome() async throws -> [[String: Any]] {
        var notices: [String: [String: Any]] = [:]
        var order: [String] = []
        for (brtc, regionName) in regions {
            var page = 1
            while true {
                let url = "https://apis.data.go.kr/1613000/HWSPR02/rsdtRcritNtcList?serviceKey=\(apiKey)&numOfRows=100&pageNo=\(page)&brtcCode=\(brtc)"
                guard let root = try await getJSON(url) as? [String: Any],
                      let response = root["response"] as? [String: Any],
                      let body = response["body"] as? [String: Any] else { break }
                var items: [[String: Any]] = []
                if let arr = body["item"] as? [[String: Any]] { items = arr }
                else if let one = body["item"] as? [String: Any] { items = [one] }

                for it in items {
                    let pblancId = "\(it["pblancId"] ?? "")"
                    let nid = "myhome-\(pblancId)"
                    if notices[nid] == nil {
                        order.append(nid)
                        notices[nid] = [
                            "id": nid,
                            "source": "마이홈",
                            "title": it["pblancNm"] as? String ?? "",
                            "status": it["sttusNm"] as? String ?? "",
                            "institution": it["suplyInsttNm"] as? String ?? "",
                            "supplyType": it["suplyTyNm"] as? String ?? "",
                            "houseType": it["houseTyNm"] as? String ?? "",
                            "region": regionName,
                            "dates": [
                                "notice": normDate(it["rcritPblancDe"] as? String),
                                "applyStart": normDate(it["beginDe"] as? String),
                                "applyEnd": normDate(it["endDe"] as? String),
                                "winner": normDate(it["przwnerPresnatnDe"] as? String),
                            ],
                            "url": (it["pcUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (it["url"] as? String ?? ""),
                            "lhPanId": extractPanId(it["url"] as? String),
                            "complexes": [[String: Any]](),
                        ]
                    }
                    let complexEntry: [String: Any] = [
                        "name": it["hsmpNm"] as? String ?? "",
                        "address": it["fullAdres"] as? String ?? "",
                        "sigungu": it["signguNm"] as? String ?? "",
                        "households": it["totHshldCo"] ?? 0,
                        "deposit": it["rentGtn"] ?? 0,
                        "monthlyRent": it["mtRntchrg"] ?? 0,
                    ]
                    var complexes = notices[nid]?["complexes"] as? [[String: Any]] ?? []
                    if !complexes.contains(where: { NSDictionary(dictionary: $0).isEqual(to: complexEntry) }) {
                        complexes.append(complexEntry)
                        notices[nid]?["complexes"] = complexes
                    }
                }
                let total = Int("\(body["totalCount"] ?? "0")") ?? 0
                if page * 100 >= total || items.isEmpty { break }
                page += 1
            }
        }
        return order.compactMap { notices[$0] }
    }

    // MARK: - LH청약플러스

    private static func fetchLHList() async throws -> [[String: Any]] {
        var notices: [[String: Any]] = []
        for (cnp, regionName) in regions {
            var page = 1
            while true {
                let url = "https://apis.data.go.kr/B552555/lhLeaseNoticeInfo1/lhLeaseNoticeInfo1?serviceKey=\(apiKey)&PG_SZ=100&PAGE=\(page)&CNP_CD=\(cnp)"
                guard let root = try await getJSON(url) as? [[String: Any]] else { break }
                let rows = root.compactMap { $0["dsList"] as? [[String: Any]] }.first ?? []
                for row in rows {
                    let upp = row["UPP_AIS_TP_CD"] as? String ?? ""
                    if lhExcludeUpp.contains(upp) { continue }
                    let panId = row["PAN_ID"] as? String ?? ""
                    notices.append([
                        "id": "lh-\(panId)",
                        "source": "LH",
                        "title": row["PAN_NM"] as? String ?? "",
                        "status": row["PAN_SS"] as? String ?? "",
                        "institution": "LH",
                        "supplyType": row["AIS_TP_CD_NM"] as? String ?? "",
                        "houseType": row["UPP_AIS_TP_NM"] as? String ?? "",
                        "region": regionName,
                        "dates": [
                            "notice": normDate(row["PAN_NT_ST_DT"] as? String),
                            "close": normDate(row["CLSG_DT"] as? String),
                        ],
                        "url": row["DTL_URL"] as? String ?? "",
                        "lhPanId": panId,
                        "complexes": [[String: Any]](),
                        "_detailParams": [
                            "PAN_ID": panId,
                            "SPL_INF_TP_CD": row["SPL_INF_TP_CD"] as? String ?? "",
                            "CCR_CNNT_SYS_DS_CD": row["CCR_CNNT_SYS_DS_CD"] as? String ?? "",
                            "UPP_AIS_TP_CD": upp,
                            "AIS_TP_CD": row["AIS_TP_CD"] as? String ?? "",
                        ],
                    ])
                }
                let allCnt = Int((rows.first?["ALL_CNT"] as? String) ?? "0") ?? 0
                if page * 100 >= allCnt || rows.isEmpty { break }
                page += 1
            }
        }
        return notices
    }

    /// 상세 조회를 동시 8개 윈도우로 병렬 실행 (순차 대비 ~8배 빠름)
    private static func enrichAll(_ notices: [[String: Any]]) async -> [[String: Any]] {
        var result = notices
        await withTaskGroup(of: (Int, [String: Any]).self) { group in
            var next = 0
            func addTask(_ i: Int) {
                group.addTask { (i, await enrichLHDetail(notices[i])) }
            }
            while next < min(8, notices.count) { addTask(next); next += 1 }
            for await (i, enriched) in group {
                result[i] = enriched
                if next < notices.count { addTask(next); next += 1 }
            }
        }
        return result
    }

    private static func enrichLHDetail(_ original: [String: Any]) async -> [String: Any] {
        var notice = original
        guard let params = notice["_detailParams"] as? [String: String] else { return notice }
        let qs = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let url = "https://apis.data.go.kr/B552555/lhLeaseNoticeDtlInfo1/getLeaseNoticeDtlInfo1?serviceKey=\(apiKey)&\(qs)"
        guard let root = try? await getJSON(url) as? [[String: Any]] else { return notice }
        let block = root.first { $0["dsSplScdl"] != nil || $0["dsSbd"] != nil } ?? [:]

        var dates = notice["dates"] as? [String: String] ?? [:]
        if let scdl = (block["dsSplScdl"] as? [[String: Any]])?.first {
            let mapping: [(String, String)] = [
                ("applyStart", "SBSC_ACP_ST_DT"), ("applyEnd", "SBSC_ACP_CLSG_DT"),
                ("docStart", "PPR_ACP_ST_DT"), ("docEnd", "PPR_ACP_CLSG_DT"),
                ("winner", "PZWR_ANC_DT"),
                ("contractStart", "CTRT_ST_DT"), ("contractEnd", "CTRT_ED_DT"),
            ]
            for (key, field) in mapping {
                let v = normDate(scdl[field] as? String)
                if !v.isEmpty { dates[key] = v }
            }
        }
        notice["dates"] = dates

        if let sbds = block["dsSbd"] as? [[String: Any]] {
            notice["complexes"] = sbds.map { sbd -> [String: Any] in
                let addr = [sbd["LGDN_ADR"] as? String ?? "", sbd["LGDN_DTL_ADR"] as? String ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return [
                    "name": sbd["LCC_NT_NM"] as? String ?? "",
                    "address": addr,
                    "households": sbd["HSH_CNT"] as? String ?? "",
                    "area": sbd["DDO_AR"] as? String ?? "",
                    "moveIn": sbd["MVIN_XPC_YM"] as? String ?? "",
                ]
            }
        }
        return notice
    }

    // MARK: - 정정공고 중복 제거

    private static func dedupeCorrections(_ notices: [[String: Any]]) -> [[String: Any]] {
        func baseTitle(_ title: String) -> String {
            var t = title
            while t.hasPrefix("[정정공고]") { t = String(t.dropFirst("[정정공고]".count)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        var groups: [String: [String: Any]] = [:]
        var order: [String] = []
        for n in notices {
            let key = [n["source"] as? String ?? "", n["region"] as? String ?? "",
                       baseTitle(n["title"] as? String ?? "")].joined(separator: "|")
            let newDate = (n["dates"] as? [String: String])?["notice"] ?? ""
            let curDate = (groups[key]?["dates"] as? [String: String])?["notice"] ?? ""
            if groups[key] == nil { order.append(key) }
            if groups[key] == nil || newDate > curDate { groups[key] = n }
        }
        return order.compactMap { groups[$0] }
    }
}

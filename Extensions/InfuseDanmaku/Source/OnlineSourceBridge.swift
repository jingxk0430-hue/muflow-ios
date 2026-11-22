import Foundation
import DanmakuCore

enum IFDSourcePolicy {
    static func normalize(_ value: String) throws -> URL {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = SiteHTTP.mediaPage(input),
              let host = url.host?.lowercased(),
              ["v.qq.com", "iqiyi.com", "youku.com", "bilibili.com", "b23.tv"]
                .contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw ServiceError.rejected("请粘贴腾讯、爱奇艺、优酷或 Bilibili 的单集视频网页链接。")
        }
        return url
    }

    static func payload(_ result: DanmakuLoadResult) -> [String: Any] {
        let comments = result.comments.filter { $0.time.isFinite && $0.time >= 0 }
            .prefix(30_000).map { item -> [String: Any] in
                var row: [String: Any] = ["time": item.time, "mode": item.advancedJSON == nil ? item.mode.rawValue : 7,
                    "color": item.color, "text": item.advancedJSON ?? String(item.text.prefix(300)),
                    "fontSize": item.sourceFontSize ?? 25]
                if let style = item.styleJSON, let bytes = style.data(using: .utf8), bytes.count <= 4096,
                   let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { row["style"] = object }
                return row
            }
        return ["comments": comments, "failedSegments": result.failedSegments,
                "truncated": result.comments.count > 30_000]
    }
}

@objc(IFDOnlineSourceBridge)
final class IFDOnlineSourceBridge: NSObject {
    @objc(loadSourceURL:completion:)
    static func loadSourceURL(_ value: String,
                             completion: @escaping ([String: Any]?, NSError?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                let source = try IFDSourcePolicy.normalize(value)
                // Direct source-site access. No external proxy, account cookies,
                // webpage video extraction or changes to Infuse video playback.
                let payload: [String: Any]
                if source.host?.hasSuffix("bilibili.com") == true || source.host == "b23.tv" {
                    let resolved = try await DanmakuSourceLink.resolve(source)
                    do { payload = try await IFDBilibiliSource.load(resolved) }
                    catch {
                        try Task.checkCancellation()
                        let fallback = try await NativeDanmakuService().commentsWithStatus(resolved, includeAdvanced: true)
                        guard !fallback.comments.isEmpty else { throw error }
                        var ordinary = IFDSourcePolicy.payload(fallback)
                        ordinary["acquisition"] = ["status": "partial", "issues": [["stage": "bilibiliAdvanced", "status": "unavailable"]]]
                        payload = ordinary
                    }
                } else {
                    let result = try await NativeDanmakuService().commentsWithStatus(source, includeAdvanced: true)
                    guard !result.comments.isEmpty else { throw DanmakuError.empty }
                    payload = IFDSourcePolicy.payload(result)
                }
                try Task.checkCancellation()
                await MainActor.run {
                    progress.completedUnitCount = 1
                    progress.cancellationHandler = nil
                    completion(payload, nil)
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let message = cancelled ? "已取消获取弹幕。" : DanmakuFailure.message(error)
                    .replacingOccurrences(of: "幕流", with: "Infuse")
                let failure = NSError(domain: "InfuseDanmaku.Source", code: cancelled ? -999 : 1,
                                      userInfo: [NSLocalizedDescriptionKey: message])
                await MainActor.run {
                    progress.cancellationHandler = nil
                    completion(nil, failure)
                }
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

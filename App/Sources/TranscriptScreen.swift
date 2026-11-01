import SwiftUI
import DshSession
import DshPresenter

/// 一份会话的正文。
///
/// 现在的数据来源是打包进 App 的一份脱敏样例会话（`sample-session.json`，和
/// `Tests/Fixtures/v4-01.json` 是同一份）。它的用途是让渲染层在**没有 host** 的情况下
/// 也能在真机上验收：节点画得出来、收起/展开正常、长会话滚得动。
/// 连真 host 之后，这里换成 `session.follow` 的流，装配链不变。
struct TranscriptScreen: View {
    let title: String
    let output: TranscriptAssembler.Output?
    let loadError: String?

    var body: some View {
        Group {
            if let output {
                ScrollView {
                    // LazyVStack：样例会话 60 个节点无所谓，但真会话 p90 有几千个事件，
                    // 非 lazy 的 VStack 会在进页面时一次性测量全部行。
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(output.nodes.enumerated()), id: \.offset) { _, node in
                            NodeView(node: node)
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(loadError ?? "没有内容")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 读取并装配打包进来的样例会话。
enum SampleSession {

    /// 夹具文件的形状：`{ name, generation, header, events: [...] }`。
    private struct File: Decodable {
        var events: [LossyDecoded<SessionEvent>]
    }

    struct Loaded {
        var output: TranscriptAssembler.Output
        var eventCount: Int
        var decodeFailures: Int
    }

    static func load() -> Result<Loaded, Error> {
        Result {
            guard let url = Bundle.main.url(forResource: "sample-session", withExtension: "json") else {
                throw LoadError.missing
            }
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            let events = file.events.compactMap(\.value)
            return Loaded(
                output: TranscriptAssembler().assemble(events),
                eventCount: file.events.count,
                decodeFailures: file.events.count - events.count
            )
        }
    }

    enum LoadError: LocalizedError {
        case missing
        var errorDescription: String? { "App 包里找不到 sample-session.json" }
    }
}

import SwiftUI
import DshProtocol
import DshSession
import DshPresenter

/// 首页。
///
/// 上半部分是"样例会话"入口：用打包进来的一份真实会话（脱敏）走完整装配链并渲染，
/// 在没有 host 的情况下验收渲染层。下半部分是核心库的几个读数——真机上看到这些数，
/// 就说明三个库都被链接进了包，而不是只编过了 App 自己。
struct ContentView: View {
    @State private var notice: String?
    private let sample = SampleSession.load()

    var body: some View {
        // iOS 15 没有 NavigationStack（iOS 16+），这里只能用 NavigationView。
        // .stack 样式避免它在大屏上变成双栏。
        NavigationView {
            List {
                Section("样例会话") {
                    switch sample {
                    case .success(let loaded):
                        NavigationLink {
                            TranscriptScreen(title: "样例会话", output: loaded.output, loadError: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("打开样例会话")
                                Text(Self.sampleCaption(loaded))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundColor(.red)
                    }
                }
                Section("核心库") {
                    row("转发事件（DshProtocol）", WireConstants.forwardedEvents.count)
                    row("需答复事件（DshProtocol）", WireConstants.waterfallEvents.count)
                    row("surface 事件类型（DshSession）", SurfaceRole.surfaceEventTypes.count)
                    row("已建模事件（DshPresenter）", EventClassifier.modeledCount)
                }
                Section {
                    Button("连接") {
                        // 配对流程（/connect 换发）还没接到界面上，先给个反馈，
                        // 免得真机验收时点了没反应被当成卡死。
                        notice = "尚未实现"
                    }
                    if let notice {
                        Text(notice).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("dsh")
        }
        .navigationViewStyle(.stack)
    }

    private static func sampleCaption(_ loaded: SampleSession.Loaded) -> String {
        var text = "事件 \(loaded.eventCount) → 节点 \(loaded.output.nodes.count)"
        if loaded.decodeFailures > 0 { text += " · 解码失败 \(loaded.decodeFailures)" }
        return text
    }

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").foregroundColor(.secondary).monospacedDigit()
        }
    }
}

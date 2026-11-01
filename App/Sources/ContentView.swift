import SwiftUI
import DshProtocol
import DshSession
import DshPresenter

/// 占位首页。
///
/// 每个核心库各取一个值显示出来：真机上看到这三个数，就说明三个库都被链接进了包，
/// 而不是只编过了 App 自己。
struct ContentView: View {
    @State private var notice: String?

    var body: some View {
        // iOS 15 没有 NavigationStack（iOS 16+），这里只能用 NavigationView。
        // .stack 样式避免它在大屏上变成双栏。
        NavigationView {
            List {
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

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").foregroundColor(.secondary).monospacedDigit()
        }
    }
}

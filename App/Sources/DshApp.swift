import SwiftUI

// App 外壳。UIKit/SwiftUI 只允许出现在 App/ 下：三个核心库要在 Linux 上跑 `swift test`，
// 任何界面代码都不能往 Sources/ 里放。
@main
struct DshApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

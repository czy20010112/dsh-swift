import Foundation

/// 摘要文本的处理。
///
/// 独立成一处是因为三个地方都要用（工具参数摘要、排队摘要、组摘要），
/// 而它们对"一行能放多少"的要求一致。放在任一个装配器里都会让另外两个
/// 去依赖它，耦合方向是错的。
public enum TextSummary {

    /// 压成一行并按字素簇截断，超出加省略号。
    ///
    /// **按字素簇而不是 UTF-16 offset**：截断点落在 emoji 或组合字符中间会产生
    /// 乱码方块。中文、`👨‍👩‍👧‍👦` 这类字符在 UTF-16 下的长度和"用户看到几个字"
    /// 完全不是一回事。
    ///
    /// **换行压成空格**：摘要只有一行，保留换行会让它渲染成看起来空白的一行。
    public static func oneLine(_ text: String, limit: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 数量的紧凑写法。思考字数动辄几千，所以上千要缩写。
    public static func compactCount(_ count: Int) -> String {
        if count < 1000 { return String(count) }
        let thousands = Double(count) / 1000.0
        // 10k 以上不显示小数位，否则一行里数字太长
        if thousands >= 10 { return String(Int(thousands.rounded())) + "k" }
        return String(format: "%.1fk", thousands)
    }

    /// 耗时的紧凑写法。
    public static func compactDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        if remainder == 0 { return "\(minutes) 分" }
        return "\(minutes) 分 \(remainder) 秒"
    }
}

import Foundation

/// 一个 DSH host 的连接坐标。
public struct HostEndpoint: Sendable, Equatable, Codable {
    /// 形如 `http://192.0.2.10:3080`。末尾不带斜杠。
    public var baseURL: URL
    /// host 启动时打印的 launch token。
    public var launchToken: String

    public init(baseURL: URL, launchToken: String) {
        self.baseURL = baseURL
        self.launchToken = launchToken
    }

    /// cookie 名所绑定的 authority（`host:port`，含端口）。
    ///
    /// 端口变了 cookie 就对不上——这是 embedded 档必须固定端口的原因。
    public var authority: String? {
        guard let host = baseURL.host else { return nil }
        if let port = baseURL.port { return "\(host):\(port)" }
        // 省略端口时 host 侧按 scheme 默认端口计算，这里保持同样口径。
        return host
    }
}

/// 换发到的凭证。
public struct HostCredential: Sendable, Equatable {
    /// cookie 名，形如 `dsh-auth-<base64url(sha256(authority))>`。
    public var cookieName: String
    /// cookie 值，形如 `v2.<payload>.<hmac>`。
    public var cookieValue: String
    /// 这份凭证能否答 waterfall。由换发时的 `interactions` 决定，**事后改不了**。
    public var interactions: WireConstants.Interactions
    /// 换发时间，用于判断 30 天有效期。
    public var issuedAt: Date

    public init(
        cookieName: String,
        cookieValue: String,
        interactions: WireConstants.Interactions,
        issuedAt: Date
    ) {
        self.cookieName = cookieName
        self.cookieValue = cookieValue
        self.interactions = interactions
        self.issuedAt = issuedAt
    }

    /// 可直接放进 `Cookie` 请求头的值。
    public var cookieHeaderValue: String { "\(cookieName)=\(cookieValue)" }
}

/// 配对失败的原因。这几种必须分开提示，否则用户无法自救。
public enum PairingError: Error, Sendable, Equatable {
    /// 403：host 的 `trustedHosts` 没有收录你访问它用的那个地址。
    ///
    /// 这是局域网/反代场景下最常见的失败，而且**和 token 对不对无关**。
    /// 提示要指向 host 配置，不要让用户去重新扫码。
    case hostNotTrusted(attemptedAuthority: String?)

    /// 401：token 不对，或 host 已经换过签名密钥。
    case tokenRejected

    /// 409：这份凭证已经在别处挂着一条 socket 了。
    ///
    /// 多设备场景下这是**预期结果**，不是异常。要重新换发一份新凭证。
    case credentialBusy

    /// host 回了 2xx/3xx 但没带 Set-Cookie，通常是打到了反代而不是 host。
    case missingCookie

    /// 响应里的 cookie 名与本地算出的 authority 对不上。
    case cookieAuthorityMismatch(expected: String, got: String)

    case transport(String)
    case badResponse(status: Int)
}

/// 把 launch token 换成会话凭证。
///
/// **为什么不走 `GET /?token=`**：那条是浏览器档，发 v1 cookie，而且所有浏览器连接
/// 共享同一个 Peer、无法声明 `interactions`。原生客户端要走 `GET /connect`。
///
/// 两条端点的实测差别（`@deepseek-ai/dsh@0.2.1-rc.5`）：
///
/// | | `GET /?token=` | `GET /connect?token=` |
/// |---|---|---|
/// | cookie 版本 | v1 | v2（payload 多 `id`） |
/// | Peer | 所有浏览器共享 | 每次换发一个独立 Peer |
/// | `interactions` | 不支持 | `answer` / `none` |
/// | 一个凭证挂多条 socket | 允许 | 第二条回 409 |
public struct PairingClient: Sendable {

    /// 执行一次换发所需的最小 HTTP 能力。抽成协议是为了能在没有网络的测试里注入假响应。
    public protocol Transport: Sendable {
        /// 发一个**不跟随重定向**的 GET。
        ///
        /// 不跟随是硬要求：凭证就在 302 响应的 `Set-Cookie` 头里，跟随之后这个头就丢了。
        func get(_ url: URL) async throws -> (status: Int, headers: [String: String])
    }

    private let transport: any Transport

    public init(transport: any Transport) {
        self.transport = transport
    }

    /// 用 launch token 换一份凭证。
    ///
    /// - Parameters:
    ///   - endpoint: host 坐标与 token。
    ///   - interactions: 本客户端要不要参与审批答复。默认 `.answer`——
    ///     手机 App 的意义就在于能在外面批准东西。注意 host 侧的默认是 `.none`，
    ///     所以这个参数必须显式传。
    public func pair(
        with endpoint: HostEndpoint,
        interactions: WireConstants.Interactions = .answer
    ) async throws -> HostCredential {
        guard var components = URLComponents(
            url: endpoint.baseURL.appendingPathComponent(WireConstants.connectPath),
            resolvingAgainstBaseURL: false
        ) else {
            throw PairingError.transport("无法构造 /connect URL")
        }
        components.queryItems = [
            URLQueryItem(name: WireConstants.tokenQueryKey, value: endpoint.launchToken),
            URLQueryItem(name: WireConstants.interactionsQueryKey, value: interactions.rawValue),
        ]
        guard let url = components.url else {
            throw PairingError.transport("无法构造 /connect URL")
        }

        let response: (status: Int, headers: [String: String])
        do {
            response = try await transport.get(url)
        } catch {
            throw PairingError.transport(String(describing: error))
        }

        switch response.status {
        case 403:
            // host 的 Host/Origin 围栏拒绝。token 可能完全正确。
            throw PairingError.hostNotTrusted(attemptedAuthority: endpoint.authority)
        case 401:
            throw PairingError.tokenRejected
        case 409:
            throw PairingError.credentialBusy
        case 200, 302, 303:
            break
        default:
            throw PairingError.badResponse(status: response.status)
        }

        guard let setCookie = Self.headerValue(response.headers, name: "set-cookie") else {
            throw PairingError.missingCookie
        }
        guard let parsed = Self.parseAuthCookie(setCookie) else {
            throw PairingError.missingCookie
        }
        if let authority = endpoint.authority {
            let expected = Self.cookieName(forAuthority: authority)
            guard expected == parsed.name else {
                throw PairingError.cookieAuthorityMismatch(expected: expected, got: parsed.name)
            }
        }
        return HostCredential(
            cookieName: parsed.name,
            cookieValue: parsed.value,
            interactions: interactions,
            issuedAt: Date()
        )
    }

    // MARK: - 解析

    /// 大小写不敏感地取一个响应头。HTTP 头名不区分大小写，而不同栈给的大小写不一样。
    static func headerValue(_ headers: [String: String], name: String) -> String? {
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target {
            return value
        }
        return nil
    }

    /// 从 `Set-Cookie` 里抠出 `dsh-auth-*` 的名与值。
    ///
    /// 只取第一段（`name=value`），后面的 `HttpOnly` / `SameSite` 等属性对客户端无意义——
    /// 我们是自己带 Cookie 头，不是浏览器。
    static func parseAuthCookie(_ setCookie: String) -> (name: String, value: String)? {
        // 一个响应可能带多条 cookie，用逗号拼接。但 cookie 的 Expires 属性里也有逗号，
        // 所以不能简单按逗号切——改为找 `dsh-auth-` 出现的位置。
        guard let start = setCookie.range(of: WireConstants.cookieNamePrefix) else { return nil }
        let tail = setCookie[start.lowerBound...]
        guard let semicolon = tail.firstIndex(of: ";") else {
            return splitPair(String(tail))
        }
        return splitPair(String(tail[..<semicolon]))
    }

    private static func splitPair(_ pair: String) -> (name: String, value: String)? {
        guard let eq = pair.firstIndex(of: "=") else { return nil }
        let name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !value.isEmpty else { return nil }
        return (name, value)
    }

    /// 算出某个 authority 对应的 cookie 名：`dsh-auth-` + base64url(sha256(authority))。
    ///
    /// 这里刻意不引入 CryptoKit——它在 Windows 上不可用，而本模块要能在 Windows 上跑测试。
    /// 改为注入哈希实现，见 `SHA256.hash`。
    public static func cookieName(forAuthority authority: String) -> String {
        let digest = SHA256.hash(Array(authority.utf8))
        return WireConstants.cookieNamePrefix + Base64URL.encode(digest)
    }
}

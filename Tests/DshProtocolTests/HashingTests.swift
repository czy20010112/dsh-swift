import XCTest
@testable import DshProtocol

/// SHA-256 与 base64url 的正确性。
///
/// 金标分两类：
/// - NIST / FIPS 180-4 的标准向量（证明 SHA-256 实现本身对）；
/// - 用 Node 的 `crypto.createHash('sha256').digest('base64url')` 算出的真值
///   （证明我们和 host 用的是同一个口径，特别是 base64url 不带填充这一点）。
final class HashingTests: XCTestCase {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testEmptyString() {
        XCTAssertEqual(
            hex(SHA256.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testAbc() {
        XCTAssertEqual(
            hex(SHA256.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// 跨 block 边界：56 字节起就要多补一个 block，这里覆盖 448 位那条经典向量。
    func testMultiBlock() {
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(
            hex(SHA256.hash(Array(input.utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    /// 1,000,000 个 'a'：验证长消息下的比特长度编码没有溢出或字节序错误。
    func testMillionAs() {
        let input = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            hex(SHA256.hash(input)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testBase64URLHasNoPadding() {
        // 空串的摘要 base64url 应为 43 字符、无 '='
        let encoded = Base64URL.encode(SHA256.hash([]))
        XCTAssertEqual(encoded, "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func testBase64URLAbc() {
        XCTAssertEqual(
            Base64URL.encode(SHA256.hash(Array("abc".utf8))),
            "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
        )
    }

    /// base64url 的三种尾部长度（0/1/2 字节余数）都要对。
    func testBase64URLRemainders() {
        XCTAssertEqual(Base64URL.encode([]), "")
        XCTAssertEqual(Base64URL.encode([0xff]), "_w")
        XCTAssertEqual(Base64URL.encode([0xff, 0xee]), "_-4")
        XCTAssertEqual(Base64URL.encode([0xff, 0xee, 0xdd]), "_-7d")
    }
}

/// cookie 名必须与 host 算的逐字符一致，否则所有请求都会被当成未认证。
///
/// 金标由 Node 算出（host 用的是同一段逻辑：
/// `'dsh-auth-' + createHash('sha256').update(authority).digest('base64url')`）。
final class CookieNameTests: XCTestCase {

    func testKnownAuthorities() {
        let cases: [(authority: String, expected: String)] = [
            ("127.0.0.1:3080", "dsh-auth-VPhEEcLKeqRDBoBalzN2Nm7CnfxKhLE00pKIDWxt1sw"),
            ("192.0.2.10:3080", "dsh-auth-h2amX9v2YbLgqFOeGDhRU3ffkKJtCkddXxScujyRDLU"),
            ("localhost", "dsh-auth-SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2M"),
            ("dsh.example.com", "dsh-auth-iCL7elxzHibFN9ZpoWkxSzYdxxxAkAZ90t81EOs4_ks"),
        ]
        for (authority, expected) in cases {
            XCTAssertEqual(
                PairingClient.cookieName(forAuthority: authority),
                expected,
                "authority \(authority) 的 cookie 名不匹配"
            )
        }
    }

    /// 端口不同 → cookie 名不同。这条是"embedded 必须固定端口"的直接证据。
    func testPortChangesCookieName() {
        let a = PairingClient.cookieName(forAuthority: "192.0.2.10:3080")
        let b = PairingClient.cookieName(forAuthority: "192.0.2.10:3081")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, "dsh-auth-vNzLelG__INHT601kxs7R6XFy2Rm5rl6VS9Z6-jh16A")
    }
}

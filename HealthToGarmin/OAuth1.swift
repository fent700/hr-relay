import Foundation
import CryptoKit

/// Minimal OAuth 1.0a (HMAC-SHA1) signer, used for Garmin's token exchange.
enum OAuth1 {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func authorizationHeader(method: String,
                                    url: URL,
                                    consumerKey: String,
                                    consumerSecret: String,
                                    token: String? = nil,
                                    tokenSecret: String? = nil,
                                    bodyParams: [String: String] = [:]) -> String {
        var oauth: [String: String] = [
            "oauth_consumer_key": consumerKey,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_version": "1.0",
        ]
        if let token { oauth["oauth_token"] = token }

        var all: [(String, String)] = oauth.map { ($0.key, $0.value) }
        all += bodyParams.map { ($0.key, $0.value) }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in comps?.queryItems ?? [] { all.append((item.name, item.value ?? "")) }

        let encoded: [(String, String)] = all.map { pair in (encode(pair.0), encode(pair.1)) }
        let sorted: [(String, String)] = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            if a.0 == b.0 { return a.1 < b.1 }
            return a.0 < b.0
        }
        let pieces: [String] = sorted.map { pair in pair.0 + "=" + pair.1 }
        let paramString: String = pieces.joined(separator: "&")

        var base = URLComponents()
        base.scheme = comps?.scheme
        base.host = comps?.host
        base.path = comps?.path ?? ""
        let baseURL = base.string ?? url.absoluteString

        let signatureBase = [method.uppercased(), encode(baseURL), encode(paramString)].joined(separator: "&")
        let signingKey = encode(consumerSecret) + "&" + encode(tokenSecret ?? "")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(signatureBase.utf8),
                                                        using: SymmetricKey(data: Data(signingKey.utf8)))
        oauth["oauth_signature"] = Data(mac).base64EncodedString()

        let header = oauth.sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\"\(encode($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth " + header
    }
}

import Foundation

// Garmin has no public upload API for individuals. This uses the same sign-in
// flow as Garmin's own mobile app (as reverse-engineered by the open-source
// `garth` library): SSO ticket → OAuth1 token (≈1 year) → short-lived OAuth2
// bearer token for connectapi.garmin.com. Garmin may change it at any time.

struct OAuth1Token: Codable { let token: String; let secret: String; let mfaToken: String? }
struct OAuth2Token: Codable { let accessToken: String; let expiresAt: Date }
struct GarminActivity { let id: Int; let start: Date; let duration: TimeInterval }

enum LoginResult { case success, needsMFA }
enum UploadResult { case uploaded(activityId: Int?), duplicate }

enum GarminError: LocalizedError {
    case loginFailed(String), notLoggedIn, http(Int, String), parse(String)
    var errorDescription: String? {
        switch self {
        case .loginFailed(let m): return "Garmin sign-in failed: \(m)"
        case .notLoggedIn: return "Not signed in to Garmin."
        case .http(let code, let body): return "Garmin returned HTTP \(code). \(body)"
        case .parse(let m): return "Unexpected Garmin response: \(m)"
        }
    }
}

actor GarminClient {
    static let shared = GarminClient()

    private let sso = "https://sso.garmin.com/sso"
    private var embed: String { sso + "/embed" }
    private let api = "https://connectapi.garmin.com"
    private let appUA = "GCM-iOS-5.7.2.1"
    private let oauthUA = "com.garmin.android.apps.connectmobile"
    private let consumerURL = URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json")!
    private let csrfPattern = #"name="_csrf"\s+value="(.+?)""#

    private var session = URLSession(configuration: .ephemeral)
    private var lastURL: URL?
    private var mfaPage: String?
    private var oauth1: OAuth1Token? = Keychain.load(OAuth1Token.self, key: "oauth1")
    private var oauth2: OAuth2Token? = Keychain.load(OAuth2Token.self, key: "oauth2")

    var isLoggedIn: Bool { oauth1 != nil }

    private var embedParams: [String: String] {
        ["id": "gauth-widget", "embedWidget": "true", "gauthHost": sso]
    }
    private var signinParams: [String: String] {
        ["id": "gauth-widget", "embedWidget": "true", "gauthHost": embed, "service": embed,
         "source": embed, "redirectAfterAccountLoginUrl": embed, "redirectAfterAccountCreationUrl": embed]
    }

    // MARK: Sign-in

    func login(email: String, password: String) async throws -> LoginResult {
        session = URLSession(configuration: .ephemeral) // fresh cookies
        lastURL = nil
        mfaPage = nil
        _ = try await ssoRequest("GET", url(embed, embedParams))
        let signinPage = try await ssoRequest("GET", url(sso + "/signin", signinParams))
        guard let csrf = firstMatch(csrfPattern, in: signinPage) else { throw GarminError.parse("no CSRF token") }
        let result = try await ssoRequest("POST", url(sso + "/signin", signinParams),
                                          form: ["username": email, "password": password,
                                                 "embed": "true", "_csrf": csrf])
        let title = firstMatch(#"<title>(.+?)</title>"#, in: result) ?? ""
        if title.contains("MFA") {
            mfaPage = result
            return .needsMFA
        }
        try await finishLogin(page: result, title: title)
        return .success
    }

    func submitMFA(code: String) async throws {
        guard let page = mfaPage, let csrf = firstMatch(csrfPattern, in: page) else {
            throw GarminError.loginFailed("MFA session expired — sign in again.")
        }
        let result = try await ssoRequest("POST", url(sso + "/verifyMFA/loginEnterMfaCode", signinParams),
                                          form: ["mfa-code": code, "embed": "true", "_csrf": csrf,
                                                 "fromPage": "setupEnterMfaCode"])
        mfaPage = nil
        try await finishLogin(page: result, title: firstMatch(#"<title>(.+?)</title>"#, in: result) ?? "")
    }

    func logout() {
        oauth1 = nil; oauth2 = nil
        Keychain.delete("oauth1"); Keychain.delete("oauth2")
    }

    private func finishLogin(page: String, title: String) async throws {
        guard title == "Success" else {
            throw GarminError.loginFailed(title.isEmpty ? "check email/password" : title)
        }
        guard let ticket = firstMatch(#"embed\?ticket=([^"]+)""#, in: page) else {
            throw GarminError.parse("no login ticket")
        }
        let consumer = try await loadConsumer()
        let preURL = url(api + "/oauth-service/oauth/preauthorized",
                         ["ticket": ticket, "login-url": embed, "accepts-mfa-tokens": "true"])
        var req = URLRequest(url: preURL)
        req.setValue(oauthUA, forHTTPHeaderField: "User-Agent")
        req.setValue(OAuth1.authorizationHeader(method: "GET", url: preURL,
                                                consumerKey: consumer.consumer_key,
                                                consumerSecret: consumer.consumer_secret),
                     forHTTPHeaderField: "Authorization")
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw GarminError.http(http.statusCode, snippet(data)) }
        let parsed = parseForm(String(decoding: data, as: UTF8.self))
        guard let t = parsed["oauth_token"], let s = parsed["oauth_token_secret"] else {
            throw GarminError.parse("no OAuth1 token")
        }
        let token = OAuth1Token(token: t, secret: s, mfaToken: parsed["mfa_token"])
        try Keychain.save(token, key: "oauth1")
        oauth1 = token
        try await exchangeOAuth2()
    }

    private func exchangeOAuth2() async throws {
        guard let o1 = oauth1 else { throw GarminError.notLoggedIn }
        let consumer = try await loadConsumer()
        let u = URL(string: api + "/oauth-service/oauth/exchange/user/2.0")!
        var form: [String: String] = [:]
        if let m = o1.mfaToken { form["mfa_token"] = m }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue(oauthUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(OAuth1.authorizationHeader(method: "POST", url: u,
                                                consumerKey: consumer.consumer_key,
                                                consumerSecret: consumer.consumer_secret,
                                                token: o1.token, tokenSecret: o1.secret,
                                                bodyParams: form),
                     forHTTPHeaderField: "Authorization")
        req.httpBody = formBody(form)
        let (data, http) = try await send(req)
        if http.statusCode == 401 || http.statusCode == 403 { logout(); throw GarminError.notLoggedIn }
        guard http.statusCode == 200 else { throw GarminError.http(http.statusCode, snippet(data)) }
        struct Resp: Decodable { let access_token: String; let expires_in: Double }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        let token = OAuth2Token(accessToken: r.access_token, expiresAt: Date().addingTimeInterval(r.expires_in - 120))
        try Keychain.save(token, key: "oauth2")
        oauth2 = token
    }

    private struct Consumer: Codable { let consumer_key: String; let consumer_secret: String }

    private func loadConsumer() async throws -> Consumer {
        if let c = Keychain.load(Consumer.self, key: "consumer") { return c }
        let (data, http) = try await send(URLRequest(url: consumerURL))
        guard http.statusCode == 200 else { throw GarminError.http(http.statusCode, "consumer key") }
        let c = try JSONDecoder().decode(Consumer.self, from: data)
        try? Keychain.save(c, key: "consumer")
        return c
    }

    // MARK: API

    /// Activities already in Garmin Connect between two dates (used for duplicate checks).
    func activities(from: Date, to: Date) async throws -> [GarminActivity] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let gmt = DateFormatter()
        gmt.locale = Locale(identifier: "en_US_POSIX")
        gmt.timeZone = TimeZone(identifier: "UTC")
        gmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var result: [GarminActivity] = []
        var start = 0
        let pageSize = 100
        while true {
            let u = url(api + "/activitylist-service/activities/search/activities",
                        ["startDate": day.string(from: from.addingTimeInterval(-86400)),
                         "endDate": day.string(from: to.addingTimeInterval(86400)),
                         "start": String(start), "limit": String(pageSize)])
            let (data, http) = try await authorized(URLRequest(url: u))
            guard http.statusCode == 200 else { throw GarminError.http(http.statusCode, snippet(data)) }
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw GarminError.parse("activity list")
            }
            for a in list {
                guard let id = (a["activityId"] as? NSNumber)?.intValue,
                      let s = a["startTimeGMT"] as? String,
                      let date = gmt.date(from: s) else { continue }
                let duration = (a["duration"] as? NSNumber)?.doubleValue ?? 0
                result.append(GarminActivity(id: id, start: date, duration: duration))
            }
            if list.count < pageSize { break }
            start += pageSize
        }
        return result
    }

    func upload(file: Data, filename: String) async throws -> UploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: api + "/upload-service/upload")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, http) = try await authorized(req)
        let text = String(decoding: data, as: UTF8.self)
        if http.statusCode == 409 || text.localizedCaseInsensitiveContains("duplicate") {
            return .duplicate
        }
        guard (200..<300).contains(http.statusCode) else { throw GarminError.http(http.statusCode, snippet(data)) }

        var id: Int?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["detailedImportResult"] as? [String: Any] {
            if let failures = result["failures"] as? [Any], !failures.isEmpty,
               (result["successes"] as? [Any])?.isEmpty ?? true {
                throw GarminError.parse("upload rejected: \(snippet(data))")
            }
            if let s = (result["successes"] as? [[String: Any]])?.first {
                id = (s["internalId"] as? NSNumber)?.intValue
            }
        }
        return .uploaded(activityId: id)
    }

    // MARK: Plumbing

    private func bearer() async throws -> String {
        if let t = oauth2, t.expiresAt > Date() { return t.accessToken }
        try await exchangeOAuth2()
        guard let t = oauth2 else { throw GarminError.notLoggedIn }
        return t.accessToken
    }

    private func authorized(_ request: URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var req = request
        let token = try await bearer()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await send(req)
        if http.statusCode == 401 && retry {
            oauth2 = nil
            Keychain.delete("oauth2")
            return try await authorized(request, retry: false)
        }
        return (data, http)
    }

    private func ssoRequest(_ method: String, _ u: URL, form: [String: String]? = nil) async throws -> String {
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        if let lastURL { req.setValue(lastURL.absoluteString, forHTTPHeaderField: "Referer") }
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(form)
        }
        let (data, http) = try await send(req)
        lastURL = http.url ?? u
        guard (200..<400).contains(http.statusCode) else {
            if http.statusCode == 429 { throw GarminError.loginFailed("too many attempts — wait and try again") }
            throw GarminError.http(http.statusCode, snippet(data))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GarminError.parse("no HTTP response") }
        return (data, http)
    }

    private func url(_ base: String, _ params: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.percentEncodedQuery = params.sorted { $0.key < $1.key }
            .map { "\(OAuth1.encode($0.key))=\(OAuth1.encode($0.value))" }
            .joined(separator: "&")
        return c.url!
    }

    private func formBody(_ params: [String: String]) -> Data {
        Data(params.map { "\(OAuth1.encode($0.key))=\(OAuth1.encode($0.value))" }
            .joined(separator: "&").utf8)
    }

    private func parseForm(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            out[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return out
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func snippet(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(200))
    }
}

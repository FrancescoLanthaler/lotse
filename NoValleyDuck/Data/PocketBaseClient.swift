import Foundation

/// Minimal read-only PocketBase REST client (public collections, no auth).
struct PocketBaseClient: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    struct Page<T: Decodable>: Decodable {
        let page: Int
        let totalPages: Int
        let items: [T]
    }

    /// All records matching `filter` (PocketBase filter syntax), following pagination.
    func list<T: Decodable>(_ collection: String, filter: String? = nil, sort: String? = nil,
                            perPage: Int = 500) async throws -> [T] {
        var all: [T] = []
        var page = 1
        while true {
            var query = ["page": "\(page)", "perPage": "\(perPage)", "skipTotal": "1"]
            if let filter { query["filter"] = filter }
            if let sort { query["sort"] = sort }
            let url = try makeURL("/api/collections/\(collection)/records", query: query)
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let p = try JSONDecoder().decode(Page<T>.self, from: data)
            all += p.items
            // With skipTotal, totalPages is -1; stop when a page comes back short.
            if p.items.count < perPage { return all }
            page += 1
        }
    }

    /// Creates (`id` nil) or updates a record; returns the record id. Public create/update rules,
    /// so no auth (see tools/setup_pocketbase.py).
    @discardableResult
    func save(_ collection: String, id: String? = nil, _ body: [String: Any]) async throws -> String {
        let path = "/api/collections/\(collection)/records" + (id.map { "/\($0)" } ?? "")
        guard let url = URL(string: baseURL.absoluteString + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = id == nil ? "POST" : "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// PocketBase date format, UTC.
    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f.string(from: d)
    }

    /// Strict percent-encoding: PocketBase filters contain `&&`, `=` and quotes, which
    /// URLComponents would leave unescaped in query values.
    private func makeURL(_ path: String, query: [String: String]) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
        guard let url = URL(string: baseURL.absoluteString + path + "?" + q) else { throw URLError(.badURL) }
        return url
    }
}

extension String {
    /// Quote a value for a PocketBase filter expression.
    var pbQuoted: String { "\"" + replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

import Foundation
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "driver")

/// Messages to the driver side (SPEC §3): the teammate's PocketBase, read by their driver web app.
/// Pickups use the existing `requests` collection. The schema has nothing for exit stops or
/// complaints yet, so those go to `facts` (public create for riders).
/// HACK: exit-stop and complaint records as `facts` until the teammate decides the schema.
struct DriverClient: Sendable {
    var client = PocketBaseClient(baseURL: Config.pocketBaseURL)

    /// "Stop at <stop>. A visually impaired passenger is waiting to board." Returns the request id.
    func pickup(stopId: String, bayId: String?, line: String, departure: Date) async throws -> String {
        let id = try await client.save("requests", [
            "stop": stopId, "bay": bayId ?? "", "line": line, "needs": ["blind"], "status": "waiting",
            // Keep it on the driver screen a while past the scheduled time; buses run late.
            "expires_at": PocketBaseClient.date(departure.addingTimeInterval(20 * 60)),
        ])
        log.info("pickup request \(id) line \(line)")
        return id
    }

    /// Rider confirmed on board, or no longer waiting.
    func setStatus(request id: String, _ status: String) async throws {
        try await client.save("requests", id: id, ["status": status])
    }

    /// "Next stop <stop>: a visually impaired passenger wants to get off."
    func stopRequest(line: String, stopName: String) async throws {
        try await fact(line: line, key: "stop_requested", value: stopName,
                       note: "A visually impaired passenger wants to get off at \(stopName).")
    }

    /// Only on an explicit "it didn't stop" (SPEC Phase 4 step 5).
    func complaint(line: String, stopName: String, scheduled: Date) async throws {
        let time = scheduled.formatted(date: .omitted, time: .shortened)
        try await fact(line: line, key: "did_not_stop", value: "\(stopName) \(time)",
                       note: "Bus \(line) did not stop at \(stopName) (scheduled \(time)) for a visually impaired passenger.")
    }

    private func fact(line: String, key: String, value: String, note: String) async throws {
        try await client.save("facts", [
            "subject_type": "vehicle", "subject_id": line, "key": key, "value": value,
            "source_role": "rider", "evidence": "none", "observed_at": PocketBaseClient.date(.now), "note": note,
        ])
        log.info("fact \(key) line \(line): \(value, privacy: .public)")
    }
}

import AppIntents

/// Placeholder destination: wraps whatever the user says verbatim, with no real place lookup yet.
/// Being an AppEntity (rather than a plain String) is what lets Siri fill it directly into a
/// phrase slot, e.g. "I need to go to \(.$destination) in NoValleyDuck".
struct DestinationEntity: AppEntity {
    let id: String
    var name: String { id }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = DestinationQuery()
}

struct DestinationQuery: EntityStringQuery {
    func entities(for identifiers: [DestinationEntity.ID]) async throws -> [DestinationEntity] {
        identifiers.map { DestinationEntity(id: $0) }
    }

    func entities(matching string: String) async throws -> [DestinationEntity] {
        [DestinationEntity(id: string)]
    }
}

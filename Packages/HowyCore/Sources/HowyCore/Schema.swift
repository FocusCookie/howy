import SwiftData

/// Version 1 of the on-disk schema. Add a `HowySchemaV2` and a migration stage to
/// `HowyMigrationPlan` before changing `Todo` in a way lightweight migration can't infer.
enum HowySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Todo.self] }
}

enum HowyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HowySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

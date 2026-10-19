public enum DiskCategory: String, Codable, CaseIterable, Sendable {
    case cache, build, dependencies, models, personal, system
}

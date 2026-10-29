import Foundation

struct GlossaryEntry: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var canonical: String
  var aliases: [String]

  init(id: UUID = UUID(), canonical: String, aliases: [String]) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
  }

  static let acme = GlossaryEntry(
    canonical: "ACME",
    aliases: ["acme"]
  )
}

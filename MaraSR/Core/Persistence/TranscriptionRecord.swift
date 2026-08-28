import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
  @Attribute(.unique) var id: UUID
  var text: String
  var createdAt: Date
  var duration: TimeInterval
  var destinationApplication: String

  init(
    id: UUID = UUID(),
    text: String,
    createdAt: Date = .now,
    duration: TimeInterval,
    destinationApplication: String
  ) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.duration = duration
    self.destinationApplication = destinationApplication
  }
}

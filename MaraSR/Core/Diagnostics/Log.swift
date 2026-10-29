import Foundation
import os

/// Unified-log channels. Notice and above are persisted, so after a crash:
///
///     /usr/bin/log show --last 1h --info \
///       --predicate 'subsystem == "com.mariano.marasr"'
///
/// Transcript text is never logged; only lengths and timings.
enum Log {
  private static let subsystem = "com.mariano.marasr"

  static let app = Logger(subsystem: subsystem, category: "app")
  static let audio = Logger(subsystem: subsystem, category: "audio")
  static let dictation = Logger(subsystem: subsystem, category: "dictation")
  static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
  static let models = Logger(subsystem: subsystem, category: "models")
  static let injection = Logger(subsystem: subsystem, category: "injection")

  static func logLaunch() {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    app.notice(
      "MaraSR \(version, privacy: .public) (\(build, privacy: .public)) launched on \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)"
    )
    NSSetUncaughtExceptionHandler { exception in
      Log.app.fault(
        "Uncaught \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)\n\(exception.callStackSymbols.joined(separator: "\n"), privacy: .public)"
      )
    }
  }
}

struct ObjCExceptionError: LocalizedError {
  let operation: String
  let name: String
  let reason: String

  var errorDescription: String? {
    reason
  }
}

enum ObjCException {
  /// Runs `body`, converting an Objective-C exception into a Swift error
  /// and logging it with its call stack. Keep `body` to the framework call
  /// itself: Swift frames inside it are still unwound by the exception.
  static func catching<T>(
    _ operation: String,
    log: Logger,
    _ body: () throws -> T
  ) throws -> T {
    var result: Result<T, Error>?
    do {
      try MRSObjCExceptionCatcher.perform {
        result = Result { try body() }
      }
    } catch let error as NSError
      where error.domain == MRSObjCExceptionErrorDomain
    {
      let name = error.userInfo[MRSObjCExceptionNameKey] as? String ?? "?"
      let reason =
        error.userInfo[MRSObjCExceptionReasonKey] as? String
        ?? error.localizedDescription
      let stack =
        (error.userInfo[MRSObjCExceptionCallStackKey] as? [String])?
        .joined(separator: "\n") ?? ""
      log.fault(
        "Caught \(name, privacy: .public) during \(operation, privacy: .public): \(reason, privacy: .public)\n\(stack, privacy: .public)"
      )
      throw ObjCExceptionError(
        operation: operation,
        name: name,
        reason: reason
      )
    }
    guard let result else {
      throw ObjCExceptionError(
        operation: operation,
        name: "NoResult",
        reason: "\(operation) did not run."
      )
    }
    return try result.get()
  }
}

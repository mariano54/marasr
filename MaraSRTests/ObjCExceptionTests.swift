import Foundation
import XCTest

@testable import MaraSR

final class ObjCExceptionTests: XCTestCase {
  func testObjCExceptionBecomesSwiftError() {
    XCTAssertThrowsError(
      try ObjCException.catching("test", log: Log.app) {
        NSException(
          name: .invalidArgumentException,
          reason: "Failed to create tap due to format mismatch"
        ).raise()
      }
    ) { error in
      let caught = error as? ObjCExceptionError
      XCTAssertEqual(caught?.name, NSExceptionName.invalidArgumentException.rawValue)
      XCTAssertEqual(caught?.reason, "Failed to create tap due to format mismatch")
      XCTAssertEqual(caught?.operation, "test")
    }
  }

  func testSwiftErrorsAndValuesPassThrough() throws {
    XCTAssertEqual(
      try ObjCException.catching("value", log: Log.app) { 42 },
      42
    )
    XCTAssertThrowsError(
      try ObjCException.catching("swift error", log: Log.app) {
        throw AudioCaptureError.inputUnavailable
      }
    ) { error in
      XCTAssertTrue(error is AudioCaptureError)
    }
  }
}

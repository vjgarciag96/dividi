import DividiKit
import Foundation
import Synchronization

/// A Source that passes reads through to another and counts how often each file is measured.
final class CountingSource: SectorSource {
  private let source: any SectorSource
  private let calls = Mutex(0)

  init(_ source: any SectorSource) {
    self.source = source
  }

  /// How many times `sectorCount(of:)` has been called.
  var sectorCountCalls: Int { calls.withLock { $0 } }

  func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data {
    try source.readSectors(sectors, of: file)
  }

  func sectorCount(of file: String) throws -> Int {
    calls.withLock { $0 += 1 }
    return try source.sectorCount(of: file)
  }
}

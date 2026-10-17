import DividiKit
import Foundation

/// A Source whose files live in memory.
struct InMemorySource: SectorSource {
  struct MissingFile: Error {}

  var files: [String: Data]

  func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data {
    guard let data = files[file] else { throw MissingFile() }
    let start = sectors.lowerBound * Sector.size
    let end = min((sectors.upperBound + 1) * Sector.size, data.count)
    return data.subdata(in: start..<end)
  }
}

import DividiKit
import Foundation

/// A Source whose files live in memory, failing the way `FolderSource` does.
struct InMemorySource: SectorSource {
  var files: [String: Data]

  func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data {
    let data = try contents(of: file)
    let start = sectors.lowerBound * Sector.size
    let end = (sectors.upperBound + 1) * Sector.size
    guard end <= data.count else { throw FolderSource.ReadError.pastEndOfFile(file) }
    return data.subdata(in: start..<end)
  }

  func sectorCount(of file: String) throws -> Int {
    try contents(of: file).count / Sector.size
  }

  private func contents(of file: String) throws -> Data {
    guard let data = files[file] else { throw FolderSource.ReadError.fileNotFound(file) }
    return data
  }
}

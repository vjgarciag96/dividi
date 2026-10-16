import Foundation

/// A Source backed by a `VIDEO_TS` folder on disk; a mounted disc is just another folder.
public struct FolderSource: SectorSource {
  public enum ReadError: Error, Equatable, LocalizedError {
    case fileNotFound(String)
    case pastEndOfFile(String)

    public var errorDescription: String? {
      switch self {
      case .fileNotFound(let file): "\(file) not found"
      case .pastEndOfFile(let file): "read past the end of \(file)"
      }
    }
  }

  /// The `VIDEO_TS` folder files are read from.
  public let videoTS: URL

  /// Accepts a `VIDEO_TS` folder or the folder containing it, matching names in any case.
  public init(url: URL) {
    videoTS = Self.child(named: "VIDEO_TS", in: url) ?? url
  }

  public func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data {
    guard let url = Self.child(named: file, in: videoTS) else {
      throw ReadError.fileNotFound(file)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(sectors.lowerBound * Sector.size))
    let count = sectors.count * Sector.size
    let data = try handle.read(upToCount: count) ?? Data()
    guard data.count == count else { throw ReadError.pastEndOfFile(file) }
    return data
  }

  private static func child(named name: String, in folder: URL) -> URL? {
    let children = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    return children?.first { $0.lastPathComponent.uppercased() == name.uppercased() }
  }
}

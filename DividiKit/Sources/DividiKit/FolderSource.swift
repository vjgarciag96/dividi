import Foundation

/// A Source backed by a `VIDEO_TS` folder on disk; a mounted disc is just another folder.
public struct FolderSource: SectorSource {
  public enum ReadError: Error, Equatable, LocalizedError {
    case fileNotFound(String)
    case pastEndOfFile(String)
    case unknownSize(String)

    public var errorDescription: String? {
      switch self {
      case .fileNotFound(let file): "\(file) not found"
      case .pastEndOfFile(let file): "read past the end of \(file)"
      case .unknownSize(let file): "the size of \(file) is unknown"
      }
    }
  }

  /// The `VIDEO_TS` folder files are read from.
  public let videoTS: URL
  /// The files in `videoTS` by upper-cased name, listed once so reads don't list the folder again.
  private let files: [String: URL]

  /// Accepts a `VIDEO_TS` folder or the folder containing it, matching names in any case.
  public init(url: URL) {
    videoTS = Self.children(of: url)["VIDEO_TS"] ?? url
    files = Self.children(of: videoTS)
  }

  public func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: try url(of: file))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(sectors.lowerBound * Sector.size))
    let count = sectors.count * Sector.size
    let data = try handle.read(upToCount: count) ?? Data()
    guard data.count == count else { throw ReadError.pastEndOfFile(file) }
    return data
  }

  public func sectorCount(of file: String) throws -> Int {
    guard let size = try url(of: file).resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      throw ReadError.unknownSize(file)
    }
    return size / Sector.size
  }

  private func url(of file: String) throws -> URL {
    guard let url = files[file.uppercased()] else {
      throw ReadError.fileNotFound(file)
    }
    return url
  }

  /// A folder's children by upper-cased name; an unreadable folder has none.
  private static func children(of folder: URL) -> [String: URL] {
    let children =
      (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []
    return Dictionary(
      children.map { ($0.lastPathComponent.uppercased(), $0) },
      uniquingKeysWith: { first, _ in first })
  }
}

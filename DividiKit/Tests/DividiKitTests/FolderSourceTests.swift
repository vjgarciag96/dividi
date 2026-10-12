import Foundation
import Testing

@testable import DividiKit

/// A temporary folder containing a `VIDEO_TS` folder, removed when the test ends.
private final class TemporaryVideoTSFolder {
  let root: URL
  let videoTS: URL

  init(videoTSName: String = "VIDEO_TS", files: [String: Data]) throws {
    root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    videoTS = root.appending(path: videoTSName)
    try FileManager.default.createDirectory(at: videoTS, withIntermediateDirectories: true)
    for (name, data) in files {
      try data.write(to: videoTS.appending(path: name))
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}

/// Three sectors, each filled with its own number.
private let threeSectors = Data((0..<3).flatMap { Array(repeating: UInt8($0), count: Sector.size) })

@Test func readsSectorsOfAFileInVideoTS() throws {
  let folder = try TemporaryVideoTSFolder(files: ["VTS_01_0.IFO": threeSectors])

  let data = try FolderSource(url: folder.videoTS).readSectors(1...2, of: "VTS_01_0.IFO")

  #expect(data == threeSectors.suffix(2 * Sector.size))
}

@Test func acceptsTheFolderContainingVideoTS() throws {
  let folder = try TemporaryVideoTSFolder(files: ["VIDEO_TS.IFO": threeSectors])

  let data = try FolderSource(url: folder.root).readSectors(0...0, of: "VIDEO_TS.IFO")

  #expect(data == threeSectors.prefix(Sector.size))
}

@Test func findsFilesWhateverTheirCase() throws {
  let folder = try TemporaryVideoTSFolder(
    videoTSName: "video_ts", files: ["vts_01_0.ifo": threeSectors])

  let data = try FolderSource(url: folder.root).readSectors(2...2, of: "VTS_01_0.IFO")

  #expect(data == threeSectors.suffix(Sector.size))
}

@Test func missingFileFails() throws {
  let folder = try TemporaryVideoTSFolder(files: [:])

  #expect(throws: FolderSource.ReadError.fileNotFound("VIDEO_TS.IFO")) {
    try FolderSource(url: folder.videoTS).readSectors(0...0, of: "VIDEO_TS.IFO")
  }
}

@Test func readingPastTheEndFails() throws {
  let folder = try TemporaryVideoTSFolder(files: ["VIDEO_TS.IFO": threeSectors])

  #expect(throws: FolderSource.ReadError.pastEndOfFile("VIDEO_TS.IFO")) {
    try FolderSource(url: folder.videoTS).readSectors(2...3, of: "VIDEO_TS.IFO")
  }
}

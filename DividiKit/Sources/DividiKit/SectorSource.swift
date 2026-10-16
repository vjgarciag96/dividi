import Foundation

/// Where Disc content is read from: answers "sectors N…M of file X".
///
/// All Disc access goes through this boundary, so a decrypting reader can be
/// added later without touching parsing, demuxing or MKV writing.
public protocol SectorSource: Sendable {
  /// Reads whole Sectors of a file in the `VIDEO_TS` folder, e.g. `VIDEO_TS.IFO`.
  func readSectors(_ sectors: ClosedRange<Int>, of file: String) throws -> Data
}

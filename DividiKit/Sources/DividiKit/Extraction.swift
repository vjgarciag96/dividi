import Foundation

/// Turns one Title into one MKV file by remuxing its original streams.
public enum Extraction {
  /// Extracts a Title's video and first AC-3 Track into an MKV file at `destination`,
  /// replacing any file already there.
  ///
  /// The MKV is written to a temporary file beside `destination` and moved into place only once
  /// it is complete, so a failed Extraction leaves no partial file behind and keeps whatever was
  /// at `destination` before.
  public static func extract(
    _ title: Title, from source: some SectorSource, to destination: URL
  ) throws {
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
    do {
      let streams = try Demuxer.streams(of: title, from: source)
      try MKV.data(video: streams.video, audio: streams.audio).write(to: temporary)
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

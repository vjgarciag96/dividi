import Foundation

/// Turns one Title into one MKV file by remuxing its original streams.
public enum Extraction {
  /// Extracts a Title's video and first AC-3 Track into an MKV file at `destination`,
  /// replacing any file already there.
  ///
  /// The MKV is written as the Title is read, to a temporary file beside `destination`, and
  /// moved into place only once it is complete, so a failed Extraction leaves no partial file
  /// behind and keeps whatever was at `destination` before. `progress` gets the fraction of the
  /// Title read so far, rising to 1.
  public static func extract(
    _ title: Title, from source: some SectorSource, to destination: URL,
    progress: (Double) -> Void = { _ in }
  ) throws {
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
    do {
      try naming(destination) { try Data().write(to: temporary) }
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        var writer = try Demuxer.demux(title, from: source, progress: progress) { video, audio in
          try MKV.Writer(
            output: FileOutput(handle, file: destination), video: video, audio: audio)
        }
        try writer.finish()
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      _ = try naming(destination) {
        try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

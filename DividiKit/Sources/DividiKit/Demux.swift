/// Why a Title's Sectors couldn't be demuxed into video and audio packets.
public enum DemuxError: Error, Equatable, Sendable {
  /// A Sector isn't a well-formed MPEG-2 program stream pack.
  case invalidPack
}

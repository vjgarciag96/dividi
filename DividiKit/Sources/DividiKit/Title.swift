/// A playable programme reachable from the Disc's title table, made of an ordered list of Cells.
public struct Title: Equatable, Sendable {
  /// The Title's 1-based position in the Disc's title table.
  public let number: Int
  /// The 1-based Title Set holding the Title's Cells.
  public let titleSet: Int
  /// The Title's declared playback time.
  public let duration: Duration
  public let chapters: [Chapter]
  /// The Cells in playback order, which may differ from their order on the Disc.
  public let cells: [Cell]
  /// The audio Tracks the Title uses.
  public let audioTracks: [AudioTrack]
  /// The subtitle Tracks the Title uses.
  public let subtitleTracks: [SubtitleTrack]
}

/// A user-visible entry point within a Title.
public struct Chapter: Equatable, Sendable {
  /// Offset from the start of the Title.
  public let start: Duration
  public let duration: Duration
}

/// A contiguous run of Sectors that a Title plays as one piece.
public struct Cell: Equatable, Sendable {
  /// Sectors within the Title Set's VOB files, taken as one continuous run.
  public let sectors: ClosedRange<Int>
  public let duration: Duration
}

/// One audio stream a Title offers.
public struct AudioTrack: Equatable, Sendable {
  public enum Codec: Equatable, Sendable {
    case ac3, mpeg1, mpeg2, lpcm, dts, unknown
  }

  public enum Kind: Equatable, Sendable {
    case unspecified, normal, visuallyImpaired, directorsComments, alternateDirectorsComments
  }

  public let codec: Codec
  public let channels: Int
  /// A raw 2-letter language code, e.g. `en`.
  public let language: String?
  public let kind: Kind
}

/// One subtitle stream a Title offers.
public struct SubtitleTrack: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case unspecified, normal, large, children
    case captions, largeCaptions, childrensCaptions
    case forced
    case directorsComments, largeDirectorsComments, childrensDirectorsComments
  }

  /// A raw 2-letter language code, e.g. `en`.
  public let language: String?
  public let kind: Kind
}

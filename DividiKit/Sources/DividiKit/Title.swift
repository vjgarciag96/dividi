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

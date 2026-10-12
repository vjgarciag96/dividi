/// A playable programme reachable from the Disc's title table.
public struct Title: Equatable, Sendable {
  /// The Title's 1-based position in the Disc's title table.
  public let number: Int
  /// The 1-based Title Set holding the Title's Cells.
  public let titleSet: Int
}

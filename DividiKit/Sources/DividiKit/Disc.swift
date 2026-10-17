import Foundation

/// The DVD-Video structure exposed by a Source, as described by its IFO files.
public struct Disc: Sendable {
  /// The Titles reachable from the Disc's title table, in title-table order.
  public let titles: [Title]

  /// Reads and parses the Disc's title table.
  public init(reading source: some SectorSource) throws(DiscError) {
    let managerFile = "VIDEO_TS.IFO"
    let manager = try parse(managerFile, from: source, as: VideoManagerIFO.init)

    var titles: [Title] = []
    for (index, entry) in manager.titles.enumerated() {
      guard entry.titleSet >= 1, entry.titleSet <= manager.titleSetCount else {
        throw DiscError(
          file: managerFile,
          reason: .invalidReference("Title \(index + 1) is in missing Title Set \(entry.titleSet)"))
      }
      titles.append(Title(number: index + 1, titleSet: entry.titleSet))
    }
    self.titles = titles
  }
}

/// Why a Source couldn't be read as a Disc.
public struct DiscError: Error, Equatable {
  public enum Reason: Error, Equatable, Sendable {
    /// The Source failed to read the file.
    case unreadable(String)
    /// The file doesn't start with an IFO signature.
    case notAnIFO
    /// A table runs past the end of the file.
    case truncated
    /// A table points at something that doesn't exist.
    case invalidReference(String)
  }

  /// The IFO that failed, e.g. `VTS_01_0.IFO`.
  public let file: String
  public let reason: Reason
}

extension DiscError: LocalizedError {
  public var errorDescription: String? {
    let reason =
      switch reason {
      case .unreadable(let description): description
      case .notAnIFO: "not an IFO file"
      case .truncated: "the file is truncated"
      case .invalidReference(let description): description
      }
    return "\(file): \(reason)"
  }
}

/// Reads a whole IFO through the Source and parses it.
private func parse<IFO>(
  _ file: String, from source: some SectorSource,
  as parse: (Data) throws(DiscError.Reason) -> IFO
) throws(DiscError) -> IFO {
  let data: Data
  do {
    let header = try source.readSectors(0...0, of: file)
    let lastSector = try ByteReader(header).u32(at: IFOHeader.lastSector)
    data = try source.readSectors(0...lastSector, of: file)
  } catch let reason as DiscError.Reason {
    throw DiscError(file: file, reason: reason)
  } catch {
    throw DiscError(file: file, reason: .unreadable(error.localizedDescription))
  }
  do {
    return try parse(data)
  } catch {
    throw DiscError(file: file, reason: error)
  }
}

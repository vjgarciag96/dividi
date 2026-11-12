import Foundation

/// A Title Set's VOB files read as the one run of Sectors that Cells count through.
///
/// On disk the run is split into `VTS_xx_1.VOB`, `VTS_xx_2.VOB` and so on, each up to 1 GB.
struct TitleSetVOBs {
  /// The 1-based Title Set.
  let titleSet: Int
  let source: any SectorSource
  /// Where each VOB file measured so far ends in the run, so each is measured only once.
  private var fileEnds: [Int] = []

  init(titleSet: Int, source: any SectorSource) {
    self.titleSet = titleSet
    self.source = source
  }

  /// Reads Sectors of the run, joining the files they're split across.
  mutating func readSectors(_ sectors: ClosedRange<Int>) throws -> Data {
    var data = Data()
    var fileStart = 0
    var fileNumber = 1
    while fileStart <= sectors.upperBound {
      let fileEnd = try end(ofFile: fileNumber, startingAt: fileStart)
      let first = max(sectors.lowerBound, fileStart)
      let last = min(sectors.upperBound, fileEnd - 1)
      if first <= last {
        data += try source.readSectors(
          (first - fileStart)...(last - fileStart), of: name(ofFile: fileNumber))
      }
      fileStart = fileEnd
      fileNumber += 1
    }
    return data
  }

  /// Where the 1-based VOB file ends in the run, given where it starts.
  private mutating func end(ofFile number: Int, startingAt start: Int) throws -> Int {
    if number <= fileEnds.count { return fileEnds[number - 1] }
    let end = start + (try source.sectorCount(of: name(ofFile: number)))
    fileEnds.append(end)
    return end
  }

  private func name(ofFile number: Int) -> String {
    String(format: "VTS_%02d_%d.VOB", titleSet, number)
  }
}

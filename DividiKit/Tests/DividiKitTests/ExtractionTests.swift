import Foundation
import Testing

@testable import DividiKit

/// A one-Title Disc whose single Cell is the whole of Title Set 1's VOB.
private func disc(vob: Data, audio: [TestAudio] = [TestAudio()]) -> InMemorySource {
  var source = TestDisc(
    titles: [TestTitle()],
    titleSets: [
      TestTitleSet(
        audio: audio,
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(
            cells: [TestCell(firstSector: 0, lastSector: vob.count / Sector.size - 1)],
            audioStreams: Array(audio.indices))
        ])
    ]
  ).source
  source.files["VTS_01_1.VOB"] = vob
  return source
}

/// One second of real MPEG-2 video and AC-3 audio, muxed as a VOB by ffmpeg.
private func realVOB(in directory: URL) throws -> Data {
  let vob = directory.appendingPathComponent("source.vob")
  try run(
    "ffmpeg",
    [
      "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1",
      "-c:v", "mpeg2video", "-bf", "2", "-g", "12", "-aspect", "16:9",
      "-c:a", "ac3", "-ac", "2", "-f", "dvd", vob.path,
    ], in: directory)
  return try Data(contentsOf: vob)
}

private func firstTitle(of source: InMemorySource) throws -> Title {
  try #require(try Disc(reading: source).titles.first)
}

/// The names of the files in a folder.
private func contents(of directory: URL) throws -> Set<String> {
  Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
}

@Test func extractsATitleIntoAnMKVFile() throws {
  try withTemporaryDirectory { directory in
    let source = disc(vob: try realVOB(in: directory))
    let output = directory.appendingPathComponent("Title 1.mkv")

    try Extraction.extract(try firstTitle(of: source), from: source, to: output)

    let result = try probe(output, in: directory)
    #expect(result.streams.map(\.codecName) == ["mpeg2video", "ac3"])
    #expect(result.packets.filter { $0.streamIndex == 0 }.count == 25, "1 s of 25 fps video")
  }
}

@Test func extractionReplacesAnExistingFile() throws {
  try withTemporaryDirectory { directory in
    let source = disc(vob: try realVOB(in: directory))
    let output = directory.appendingPathComponent("Title 1.mkv")
    try Data("old".utf8).write(to: output)

    try Extraction.extract(try firstTitle(of: source), from: source, to: output)

    #expect(try probe(output, in: directory).streams.map(\.codecName) == ["mpeg2video", "ac3"])
  }
}

@Test func failedExtractionLeavesNothingBehind() throws {
  try withTemporaryDirectory { directory in
    let source = disc(vob: try realVOB(in: directory), audio: [TestAudio(codingMode: 4)])
    let output = directory.appendingPathComponent("Title 1.mkv")
    let before = try contents(of: directory)

    #expect(throws: DemuxError.noAC3Track) {
      try Extraction.extract(try firstTitle(of: source), from: source, to: output)
    }
    #expect(try contents(of: directory) == before, "no output or temporary file should remain")
  }
}

@Test func failedExtractionKeepsTheFileItWouldHaveReplaced() throws {
  try withTemporaryDirectory { directory in
    let vob = try realVOB(in: directory)
    // A Cell running past the end of the only VOB fails once the Extraction is under way.
    var source = disc(vob: vob)
    source.files["VTS_01_1.VOB"] = vob.prefix(vob.count / 2)
    let output = directory.appendingPathComponent("Title 1.mkv")
    try Data("old".utf8).write(to: output)
    let before = try contents(of: directory)

    #expect(throws: FolderSource.ReadError.fileNotFound("VTS_01_2.VOB")) {
      try Extraction.extract(try firstTitle(of: source), from: source, to: output)
    }
    #expect(try Data(contentsOf: output) == Data("old".utf8))
    #expect(try contents(of: directory) == before, "no temporary file should remain")
  }
}

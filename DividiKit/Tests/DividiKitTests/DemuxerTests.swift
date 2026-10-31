import Foundation
import Testing

@testable import DividiKit

/// One Cell's packs: a navigation pack, then a group of three pictures 40 ms apart and four
/// 32 ms AC-3 frames, each in its own pack, all starting at `presentation`.
private func cellPacks(presentation: Int, substream: Int = 0) -> Data {
  var packs = TestPack.navigation()
  for index in 0..<3 {
    var picture = TestMPEG2Video.picture(temporalReference: index, type: index == 0 ? 1 : 2)
    if index == 0 {
      picture = TestMPEG2Video.sequenceHeader() + TestMPEG2Video.groupOfPictures() + picture
    }
    packs += TestPack.pack([
      TestPES(streamID: 0xE0, presentation: presentation + 3_600 * index, payload: picture)
    ])
  }
  for index in 0..<4 {
    packs += TestPack.pack([
      TestPES(
        streamID: 0xBD, substream: UInt8(0x80 + substream),
        presentation: presentation + 2_880 * index,
        payload: TestAC3.frame(frameSizeCode: 16, size: 512, filler: UInt8(index)))
    ])
  }
  return packs
}

/// The number of Sectors `cellPacks` takes.
private let cellSectors = 8

/// A Disc with one Title playing the Cells, in order, from Title Set 1's VOB.
private func disc(
  cells: [ClosedRange<Int>], vob: Data, audio: [TestAudio] = [TestAudio()],
  audioSubstreams: [Int: Int] = [:], angles: Int = 1
) -> InMemorySource {
  var source = TestDisc(
    titles: [TestTitle(angles: angles)],
    titleSets: [
      TestTitleSet(
        audio: audio,
        chapters: [[(programChain: 1, program: 1)]],
        programChains: [
          TestProgramChain(
            cells: cells.map { TestCell(firstSector: $0.lowerBound, lastSector: $0.upperBound) },
            audioStreams: Array(audio.indices), audioSubstreams: audioSubstreams)
        ])
    ]
  ).source
  source.files["VTS_01_1.VOB"] = vob
  return source
}

private func demux(_ source: InMemorySource) throws -> (video: MKV.Video, audio: MKV.Audio) {
  let title = try #require(try Disc(reading: source).titles.first)
  return try Demuxer.streams(of: title, from: source)
}

@Test func singleCellTitleStartsAtZero() throws {
  let source = disc(cells: [0...cellSectors - 1], vob: cellPacks(presentation: 90_000))

  let (video, audio) = try demux(source)

  #expect(video.width == 720)
  #expect(video.height == 576)
  #expect(video.displayAspect == .fourByThree)
  #expect(video.packets.map(\.presentation) == [0, 40, 80].map { .milliseconds($0) })
  #expect(video.packets.map(\.duration) == Array(repeating: .milliseconds(40), count: 3))
  #expect(video.packets.map(\.isKeyframe) == [true, false, false])
  #expect(audio.sampleRate == 48_000)
  #expect(audio.channels == 2)
  #expect(audio.packets.map(\.presentation) == [0, 32, 64, 96].map { .milliseconds($0) })
  #expect(audio.packets.map(\.duration) == Array(repeating: .milliseconds(32), count: 4))
  #expect(
    audio.packets.map(\.bytes)
      == (0..<4).map { TestAC3.frame(frameSizeCode: 16, size: 512, filler: UInt8($0)) })
}

@Test func cellsPlayInPlaybackOrderOneAfterAnother() throws {
  // The second Cell on the Disc plays first. Each Cell lasts 128 ms, its last audio frame's end.
  let vob = cellPacks(presentation: 90_000) + cellPacks(presentation: 200_000)
  let source = disc(cells: [cellSectors...2 * cellSectors - 1, 0...cellSectors - 1], vob: vob)

  let (video, audio) = try demux(source)

  #expect(
    video.packets.map(\.presentation) == [0, 40, 80, 128, 168, 208].map { .milliseconds($0) })
  #expect(
    audio.packets.map(\.presentation)
      == [0, 32, 64, 96, 128, 160, 192, 224].map { .milliseconds($0) })
}

@Test func timestampsStayContinuousWhenACellResetsThem() throws {
  let vob = cellPacks(presentation: 500_000) + cellPacks(presentation: 0)
  let source = disc(cells: [0...cellSectors - 1, cellSectors...2 * cellSectors - 1], vob: vob)

  let (video, _) = try demux(source)

  #expect(
    video.packets.map(\.presentation) == [0, 40, 80, 128, 168, 208].map { .milliseconds($0) })
}

@Test func audioComesFromTheFirstAC3TracksSubstream() throws {
  let source = disc(
    cells: [0...cellSectors - 1], vob: cellPacks(presentation: 0, substream: 3),
    audio: [TestAudio(codingMode: 4), TestAudio(codingMode: 0)], audioSubstreams: [0: 0, 1: 3])

  let (_, audio) = try demux(source)

  #expect(audio.packets.count == 4)
}

@Test func titleWithoutAnAC3TrackFails() {
  let source = disc(
    cells: [0...cellSectors - 1], vob: cellPacks(presentation: 0),
    audio: [TestAudio(codingMode: 4)])

  #expect(throws: DemuxError.noAC3Track) { try demux(source) }
}

@Test func unsupportedTitleIsRejectedWithItsReason() {
  let source = disc(cells: [0...cellSectors - 1], vob: cellPacks(presentation: 0), angles: 2)

  #expect(throws: DemuxError.unsupportedTitle(.multiAngle)) { try demux(source) }
}

@Test func realStreamsSurviveDemuxingAndWriting() throws {
  try withTemporaryDirectory { directory in
    // The VOB holds the source's packets as they are; only the container changes.
    let source = directory.appendingPathComponent("source.mkv")
    let vob = directory.appendingPathComponent("VTS_01_1.VOB")
    let output = directory.appendingPathComponent("output.mkv")
    try run(
      "ffmpeg",
      [
        "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2",
        "-c:v", "mpeg2video", "-bf", "2", "-g", "12", "-aspect", "16:9",
        // A DVD player's buffer, so the VOB muxer can schedule the packets.
        "-b:v", "6M", "-maxrate", "9M", "-bufsize", "1835k",
        "-c:a", "ac3", "-ac", "2", source.path,
      ], in: directory)
    try run("ffmpeg", ["-i", source.path, "-c", "copy", "-f", "dvd", vob.path], in: directory)
    let data = try Data(contentsOf: vob)

    let streams = try demux(disc(cells: [0...data.count / Sector.size - 1], vob: data))
    try MKV.data(video: streams.video, audio: streams.audio).write(to: output)

    let original = try probe(source, in: directory)
    let result = try probe(output, in: directory)
    let offset = try #require(original.packets.map(\.time).min())
    #expect(result.streams.map(\.codecName) == ["mpeg2video", "ac3"])
    #expect(result.streams[0].displayAspectRatio == "16:9")
    for index in 0...1 {
      let before = original.packets.filter { $0.streamIndex == index }
      let after = result.packets.filter { $0.streamIndex == index }
      #expect(before.count == after.count)
      for (a, b) in zip(before, after) {
        #expect(try a.payload() == b.payload())
        #expect(a.flags.contains("K") == b.flags.contains("K"))
        #expect(abs(a.time - offset - b.time) <= 0.001)
      }
    }
    #expect(
      try decodedHashes(source, map: "0:v:0", in: directory)
        == decodedHashes(output, map: "0:v:0", in: directory))
  }
}

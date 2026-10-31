import Foundation
import Testing

@testable import DividiKit

@Test func videoPacketKeepsItsTimestampsAndPayload() throws {
  let pack = TestPack.pack([
    TestPES(streamID: 0xE0, presentation: 93_600, decoding: 90_000, payload: Data([1, 2, 3]))
  ])

  #expect(
    try ProgramStream.packets(inPack: pack) == [
      PESPacket(stream: .video, presentation: 93_600, decoding: 90_000, payload: Data([1, 2, 3]))
    ])
}

@Test func packetWithoutTimestampsHasNone() throws {
  let pack = TestPack.pack([TestPES(streamID: 0xE0, payload: Data([4, 5]))])

  #expect(
    try ProgramStream.packets(inPack: pack) == [
      PESPacket(stream: .video, presentation: nil, decoding: nil, payload: Data([4, 5]))
    ])
}

@Test func timestampsUseAll33Bits() throws {
  let pack = TestPack.pack([
    TestPES(streamID: 0xE0, presentation: 0x1_FFFF_FFFF, payload: Data([0]))
  ])

  #expect(try ProgramStream.packets(inPack: pack).map(\.presentation) == [0x1_FFFF_FFFF])
}

@Test func ac3PacketsAreGroupedBySubstreamWithoutTheirSubstreamHeader() throws {
  let pack = TestPack.pack([
    TestPES(streamID: 0xBD, substream: 0x80, presentation: 3_000, payload: Data([0x0B, 0x77])),
    TestPES(streamID: 0xBD, substream: 0x82, presentation: 3_000, payload: Data([0x0B, 0x78])),
  ])

  #expect(
    try ProgramStream.packets(inPack: pack) == [
      PESPacket(stream: .ac3(0), presentation: 3_000, decoding: nil, payload: Data([0x0B, 0x77])),
      PESPacket(stream: .ac3(2), presentation: 3_000, decoding: nil, payload: Data([0x0B, 0x78])),
    ])
}

@Test func navigationPacksHaveNoPackets() throws {
  #expect(try ProgramStream.packets(inPack: TestPack.navigation()) == [])
}

@Test func otherStreamsAreSkipped() throws {
  let pack = TestPack.pack([
    TestPES(streamID: 0xBD, substream: 0x20, presentation: 0, payload: Data([9])),  // subtitles
    TestPES(streamID: 0xBD, substream: 0xA0, presentation: 0, payload: Data([9])),  // LPCM
    TestPES(streamID: 0xC0, presentation: 0, payload: Data([9])),  // MPEG audio
    TestPES(streamID: 0xE0, payload: Data([7])),
  ])

  #expect(try ProgramStream.packets(inPack: pack).map(\.stream) == [.video])
}

@Test func sectorThatIsNotAPackFails() {
  #expect(throws: DemuxError.invalidPack) {
    try ProgramStream.packets(inPack: Data(count: Sector.size))
  }
}

@Test func packetRunningPastThePackFails() {
  var pack = TestPack.pack([TestPES(streamID: 0xE0, payload: Data([7]))])
  pack = pack.prefix(20)

  #expect(throws: DemuxError.invalidPack) {
    try ProgramStream.packets(inPack: pack)
  }
}

@Test func realProgramStreamMatchesFFmpeg() throws {
  try withTemporaryDirectory { directory in
    let vob = directory.appendingPathComponent("source.vob")
    try run(
      "ffmpeg",
      [
        "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "1", "-c:v", "mpeg2video", "-bf", "2", "-g", "12",
        "-c:a", "ac3", "-ac", "2", "-f", "dvd", vob.path,
      ], in: directory)
    let data = try Data(contentsOf: vob)
    #expect(data.count % Sector.size == 0)

    var packets: [PESPacket] = []
    for start in stride(from: 0, to: data.count, by: Sector.size) {
      packets += try ProgramStream.packets(inPack: data.subdata(in: start..<start + Sector.size))
    }

    for (stream, format, map) in [
      (PESPacket.Stream.video, "mpeg2video", "0:v:0"), (.ac3(0), "ac3", "0:a:0"),
    ] {
      let elementary = try run(
        "ffmpeg", ["-i", vob.path, "-map", map, "-c", "copy", "-f", format, "-"], in: directory)
      let ours = packets.filter { $0.stream == stream }
      #expect(ours.reduce(Data()) { $0 + $1.payload } == elementary)

      // ffprobe lists the navigation stream first, then video, then audio.
      let streamIndex = stream == .video ? 1 : 2
      let timestamps = Set(
        try probe(vob, in: directory).packets.filter { $0.streamIndex == streamIndex }
          .map { Int(($0.time * 90_000).rounded()) })
      let ourTimestamps = ours.compactMap(\.presentation)
      #expect(!ourTimestamps.isEmpty)
      #expect(Set(ourTimestamps).isSubset(of: timestamps))
    }
  }
}

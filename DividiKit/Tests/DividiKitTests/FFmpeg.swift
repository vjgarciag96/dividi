import Foundation
import Testing

// Runs ffmpeg and ffprobe so tests can check real streams against them.

struct Probe: Decodable {
  struct Packet: Decodable {
    var streamIndex: Int
    var ptsTime: String
    var durationTime: String
    var flags: String
    var data: String
    var time: Double { Double(ptsTime)! }

    func payload() throws -> Data {
      var bytes = Data()
      for line in data.split(separator: "\n") {
        let afterAddress = try #require(line.split(separator: ":", maxSplits: 1).last)
        let hex = afterAddress.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ")[0]
          .replacingOccurrences(of: " ", with: "")
        var index = hex.startIndex
        while index < hex.endIndex {
          let end = hex.index(index, offsetBy: 2)
          bytes.append(try #require(UInt8(hex[index..<end], radix: 16)))
          index = end
        }
      }
      return bytes
    }
  }
  struct Stream: Decodable {
    var codecName: String
    var displayAspectRatio: String?
  }
  struct Format: Decodable { var duration: String }
  var packets: [Packet]
  var streams: [Stream]
  var format: Format
}

func probe(_ url: URL, in directory: URL) throws -> Probe {
  let output = try run(
    "ffprobe",
    ["-show_packets", "-show_data", "-show_streams", "-show_format", "-of", "json", url.path],
    in: directory)
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(Probe.self, from: output)
}

func decodedHashes(_ url: URL, map: String, in directory: URL) throws -> [String] {
  let output = try run(
    "ffmpeg",
    ["-xerror", "-i", url.path, "-map", map, "-f", "framemd5", "-"],
    in: directory)
  let rows = String(decoding: output, as: UTF8.self).split(separator: "\n").filter {
    !$0.hasPrefix("#")
  }
  #expect(!rows.isEmpty)
  return rows.map { row in
    let fields = row.split(separator: ",")
    return "\(fields[4]):\(fields[5])"
  }
}

private struct ToolFailure: Error, CustomStringConvertible { let description: String }

@discardableResult
func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> Data {
  let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
  let executable = try #require(
    paths.map { URL(fileURLWithPath: String($0)).appendingPathComponent(tool) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) })
  let stdout = directory.appendingPathComponent(UUID().uuidString)
  let stderr = directory.appendingPathComponent(UUID().uuidString)
  FileManager.default.createFile(atPath: stdout.path, contents: nil)
  FileManager.default.createFile(atPath: stderr.path, contents: nil)
  let outputHandle = try FileHandle(forWritingTo: stdout)
  let errorHandle = try FileHandle(forWritingTo: stderr)
  defer {
    try? outputHandle.close()
    try? errorHandle.close()
  }
  let process = Process()
  process.executableURL = executable
  process.arguments = ["-v", "error"] + arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = outputHandle
  process.standardError = errorHandle
  try process.run()
  process.waitUntilExit()
  let errors = try String(contentsOf: stderr, encoding: .utf8)
  guard process.terminationStatus == 0, errors.isEmpty else {
    throw ToolFailure(description: "\(tool) exited \(process.terminationStatus): \(errors)")
  }
  return try Data(contentsOf: stdout)
}

func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

func seconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

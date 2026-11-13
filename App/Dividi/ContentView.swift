import AppKit
import DividiKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  private enum Phase {
    case empty
    case reading
    case read([Title])
    case failed(String)
  }

  /// Where the Extraction of one Title stands.
  private enum ExtractionState {
    case idle
    case running(title: Int)
    case finished(title: Int, file: URL)
    case failed(title: Int, reason: String)
  }

  @State private var phase = Phase.empty
  @State private var isPickingFolder = false
  @State private var folder: URL?
  @State private var selection: Title.ID?
  @State private var extraction = ExtractionState.idle

  var body: some View {
    content
      .frame(minWidth: 720, minHeight: 320)
      .navigationSubtitle(folder?.lastPathComponent ?? "")
      .toolbar {
        Button("Open…", systemImage: "folder") { isPickingFolder = true }
          .disabled(isReading || isExtracting)
        Button("Extract…", systemImage: "square.and.arrow.down") {
          if let selectedTitle { extract(selectedTitle) }
        }
        .disabled(!(selectedTitle.map { $0.unsupportedReason == nil } ?? false) || isExtracting)
      }
      .safeAreaInset(edge: .bottom) { statusBar }
      .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { read(url) }
      }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .empty:
      ContentUnavailableView {
        Label("No Source", systemImage: "opticaldiscdrive")
      } description: {
        Text("Open a VIDEO_TS folder, or the folder containing it.")
      } actions: {
        Button("Open…") { isPickingFolder = true }
      }
    case .reading:
      ProgressView("Reading Disc…")
    case .read(let titles):
      TitleTable(titles: titles, selection: $selection)
    case .failed(let message):
      ContentUnavailableView(
        "Couldn't Read Disc", systemImage: "exclamationmark.triangle",
        description: Text(message))
    }
  }

  @ViewBuilder private var statusBar: some View {
    switch extraction {
    case .idle:
      EmptyView()
    case .running(let title):
      StatusBar {
        ProgressView().controlSize(.small)
        Text("Extracting Title \(title)…")
      }
    case .finished(let title, let file):
      StatusBar {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Extracted Title \(title) to \(file.lastPathComponent).")
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
      }
    case .failed(let title, let reason):
      StatusBar {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        Text("Couldn't extract Title \(title): \(reason.hasSuffix(".") ? reason : reason + ".")")
      }
    }
  }

  private var isReading: Bool {
    if case .reading = phase { true } else { false }
  }

  private var isExtracting: Bool {
    if case .running = extraction { true } else { false }
  }

  private var selectedTitle: Title? {
    guard case .read(let titles) = phase else { return nil }
    return titles.first { $0.id == selection }
  }

  private func extract(_ title: Title) {
    guard let folder else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "mkv") ?? .movie]
    panel.nameFieldStringValue = "Title \(title.number).mkv"
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    extraction = .running(title: title.number)
    Task {
      let accessing = folder.startAccessingSecurityScopedResource()
      defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
      do {
        try await Task.detached {
          try Extraction.extract(title, from: FolderSource(url: folder), to: destination)
        }.value
        extraction = .finished(title: title.number, file: destination)
      } catch {
        extraction = .failed(title: title.number, reason: error.localizedDescription)
      }
    }
  }

  private func read(_ url: URL) {
    folder = url
    selection = nil
    extraction = .idle
    phase = .reading
    Task {
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      do {
        let disc = try await Task.detached { try Disc(reading: FolderSource(url: url)) }.value
        phase = .read(disc.titles)
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

/// A one-line bar along the bottom of the window.
private struct StatusBar<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 8) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
  }
}

private struct TitleTable: View {
  let titles: [Title]
  @Binding var selection: Title.ID?

  var body: some View {
    Table(titles, selection: $selection) {
      TableColumn("Title") { Text($0.number, format: .number) }
        .width(40)
      TableColumn("Duration") { Text($0.duration, format: .time(pattern: .hourMinuteSecond)) }
        .width(70)
      TableColumn("Chapters") { Text($0.chapters.count, format: .number) }
        .width(60)
      TableColumn("Audio") {
        Text($0.audioTracks.map(\.label).formatted(.list(type: .and, width: .narrow)))
      }
      TableColumn("Subtitles") {
        Text($0.subtitleTracks.map(\.label).formatted(.list(type: .and, width: .narrow)))
      }
      TableColumn("Status") { Text($0.status) }
        .width(min: 80, ideal: 160)
    }
  }
}

extension Title {
  fileprivate var status: String {
    switch unsupportedReason {
    case nil: String(localized: "OK", comment: "Status of a Title dividi can extract")
    case .multiAngle:
      String(localized: "Unsupported: multi-angle", comment: "Status of a multi-angle Title")
    case .seamlessBranching:
      String(
        localized: "Unsupported: seamless branching",
        comment: "Status of a Title using seamless branching")
    }
  }
}

extension AudioTrack {
  /// E.g. "en AC-3 6ch (commentary)".
  fileprivate var label: String {
    let language = language ?? unknownLanguage
    let codec =
      switch codec {
      case .ac3: "AC-3"
      case .mpeg1: "MPEG-1"
      case .mpeg2: "MPEG-2"
      case .lpcm: "LPCM"
      case .dts: "DTS"
      case .unknown: String(localized: "unknown", comment: "Codec of an audio Track")
      }
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .visuallyImpaired:
        String(localized: "visually impaired", comment: "Kind of audio Track")
      case .directorsComments, .alternateDirectorsComments:
        String(localized: "commentary", comment: "Kind of audio or subtitle Track")
      }
    guard let kind else {
      return String(
        localized: "\(language) \(codec) \(channels)ch",
        comment: "Audio Track: language code, codec, channel count")
    }
    return String(
      localized: "\(language) \(codec) \(channels)ch (\(kind))",
      comment: "Audio Track: language code, codec, channel count, kind")
  }
}

extension SubtitleTrack {
  /// E.g. "en (forced)".
  fileprivate var label: String {
    let language = language ?? unknownLanguage
    let kind: String? =
      switch kind {
      case .unspecified, .normal: nil
      case .large: String(localized: "large", comment: "Kind of subtitle Track")
      case .children: String(localized: "children", comment: "Kind of subtitle Track")
      case .captions: String(localized: "captions", comment: "Kind of subtitle Track")
      case .largeCaptions: String(localized: "large captions", comment: "Kind of subtitle Track")
      case .childrensCaptions:
        String(localized: "children's captions", comment: "Kind of subtitle Track")
      case .forced: String(localized: "forced", comment: "Kind of subtitle Track")
      case .directorsComments, .largeDirectorsComments, .childrensDirectorsComments:
        String(localized: "commentary", comment: "Kind of audio or subtitle Track")
      }
    guard let kind else { return language }
    return String(
      localized: "\(language) (\(kind))", comment: "Subtitle Track: language code, kind")
  }
}

/// Shown in place of a Track's language code when the Disc doesn't give one.
private let unknownLanguage = String(
  localized: "??", comment: "Placeholder for a Track's missing language code")

#Preview {
  ContentView()
}

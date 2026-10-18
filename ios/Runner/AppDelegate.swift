import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let library = MusicLibrary()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "MusicLibrary")!.messenger()
    FlutterMethodChannel(name: "com.novaplayer/music_library", binaryMessenger: messenger)
      .setMethodCallHandler(library.handle)
  }
}

/// iOS side of the music_library channel. Songs are the audio files the user
/// copies into the app's Documents folder (Finder or the Files app), plus
/// folders picked in the Files app; the Apple Music library is not used,
/// since its songs are mostly DRM protected.
final class MusicLibrary: NSObject, UIDocumentPickerDelegate {
  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf",
  ]  // AVPlayer cannot play Ogg or Opus.
  private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  private var onPick: (([URL]) -> Void)?
  /// Picked folders, with access kept open so their songs stay playable.
  private var folders: [URL] = []
  private static let foldersKey = "music_folders"

  override init() {
    super.init()
    for bookmark in UserDefaults.standard.array(forKey: Self.foldersKey) as? [Data] ?? [] {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
        url.startAccessingSecurityScopedResource()
      {
        folders.append(url)
      }
    }
  }

  private func saveFolders() {
    UserDefaults.standard.set(folders.compactMap { try? $0.bookmarkData() }, forKey: Self.foldersKey)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getSongs":
      Task.detached { [documents, folders] in
        let songs = await Self.scan(documents, folders)
        await MainActor.run { result(songs) }
      }
    case "getArtwork":
      let size = args["size"] as? Int
      guard let url = (args["uri"] as? String).flatMap(URL.init(string:)) else {
        return result(FlutterError(code: "INVALID_URI", message: "A song URI is required", details: nil))
      }
      Task.detached {
        let bytes = await Self.artwork(url, size: size)
        await MainActor.run { result(bytes) }
      }
    case "getLyrics":
      guard let url = (args["uri"] as? String).flatMap(URL.init(string:)) else { return result(nil) }
      Task.detached {
        let lyrics = await Self.lyrics(url)
        await MainActor.run { result(lyrics) }
      }
    case "getFilesDir":
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      result(support.path)
    case "saveTextFile":
      let name = (args["name"] as? String) ?? "nova.txt"
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      do {
        try ((args["text"] as? String) ?? "").write(to: file, atomically: true, encoding: .utf8)
      } catch {
        return result(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
      }
      pick(UIDocumentPickerViewController(forExporting: [file], asCopy: true), result) { urls in
        result(urls.isEmpty ? nil : file.lastPathComponent)
      }
    case "openTextFile":
      pick(UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true), result) { urls in
        result(urls.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
      }
    case "restartApp":
      // iOS apps cannot relaunch themselves; restored settings load on the next open.
      exit(0)
    case "getMusicFolders":
      result(folders.map { ["uri": $0.absoluteString, "name": $0.lastPathComponent] })
    case "addMusicFolder":
      pick(UIDocumentPickerViewController(forOpeningContentTypes: [.folder]), result) { [self] urls in
        guard let url = urls.first, url.startAccessingSecurityScopedResource() else { return result(false) }
        if !folders.contains(url) { folders.append(url) }
        saveFolders()
        result(true)
      }
    case "removeMusicFolder":
      if let index = folders.firstIndex(where: { $0.absoluteString == args["uri"] as? String }) {
        folders.remove(at: index).stopAccessingSecurityScopedResource()
        saveFolders()
      }
      result(nil)
    case "getLyricsFolder":
      result(nil)
    case "rescanStorage", "pickLyricsFolder", "clearLyricsFolder", "updateWidget":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Library scan

  /// Songs in Documents, then in each picked folder; a file reachable from
  /// two roots (a picked folder inside Documents) is listed once.
  private static func scan(_ documents: URL, _ folders: [URL]) async -> [[String: Any]] {
    var seen = Set<String>()
    var songs: [[String: Any]] = []
    for (root, label) in [(documents, nil)] + folders.map({ ($0, $0.lastPathComponent) }) {
      // Not-downloaded iCloud files are hidden ".name.icloud" stubs, so they are skipped.
      guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      else { continue }
      var urls: [URL] = []
      for case let url as URL in files
      where audioExtensions.contains(url.pathExtension.lowercased())
        && seen.insert(url.resolvingSymlinksInPath().path).inserted
      {
        urls.append(url)
      }
      for url in urls {
        songs.append(await song(url, root: root, label: label))
      }
    }
    return songs
  }

  private static func song(_ url: URL, root: URL, label: String?) async -> [String: Any] {
    let asset = AVURLAsset(url: url)
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
    let rootPath = root.resolvingSymlinksInPath().path
    let inRoot = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1))
    let relative = label.map { "\($0)/\(inRoot)" } ?? inRoot
    var title: String?, artist: String?, album: String?, genre: String?, year = 0
    let items = (try? await asset.load(.metadata)) ?? []
    for item in items {
      guard let key = item.commonKey ?? (item.key as? String).map(AVMetadataKey.init(rawValue:))
      else { continue }
      let value = try? await item.load(.stringValue)
      switch key {
      case .commonKeyTitle: title = title ?? value
      case .commonKeyArtist: artist = artist ?? value
      case .commonKeyAlbumName: album = album ?? value
      case .id3MetadataKeyContentType, .iTunesMetadataKeyUserGenre:
        genre = genre ?? value
      case .commonKeyCreationDate, .id3MetadataKeyYear, .id3MetadataKeyRecordingTime,
        .iTunesMetadataKeyReleaseDate:
        year = year > 0 ? year : Int(value?.prefix(4) ?? "") ?? 0
      default: break
      }
    }
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
    let folder = (relative as NSString).deletingLastPathComponent
    return [
      // Relative path: unlike the container path, it survives app updates.
      "id": relative,
      "title": title ?? url.deletingPathExtension().lastPathComponent,
      "artist": artist as Any,
      "album": album as Any,
      "genre": genre as Any,
      "year": year,
      "duration": duration.isFinite ? Int(duration * 1000) : 0,
      "fileName": url.lastPathComponent,
      "mimeType": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "",
      "dateAdded": Int((values?.creationDate?.timeIntervalSince1970 ?? 0) * 1000),
      "size": values?.fileSize ?? 0,
      "folder": folder.isEmpty ? "Nova Player" : folder,
      "path": url.path,
      "uri": url.absoluteString,
    ]
  }

  // MARK: Artwork and lyrics

  private static func artwork(_ url: URL, size: Int?) async -> FlutterStandardTypedData? {
    let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
    for item in items where item.commonKey == .commonKeyArtwork {
      guard let data = try? await item.load(.dataValue) else { continue }
      guard let size, let image = UIImage(data: data) else { return FlutterStandardTypedData(bytes: data) }
      let scale = CGFloat(size) / max(min(image.size.width, image.size.height), 1)
      guard scale < 1 else { return FlutterStandardTypedData(bytes: data) }
      let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let thumbnail = UIGraphicsImageRenderer(size: target).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
      }
      return thumbnail.jpegData(compressionQuality: 0.85).map(FlutterStandardTypedData.init(bytes:))
    }
    return nil
  }

  /// Embedded lyrics, else a .lrc file with the same name next to the song.
  private static func lyrics(_ url: URL) async -> String? {
    if let embedded = try? await AVURLAsset(url: url).load(.lyrics), !embedded.isEmpty {
      return embedded
    }
    return try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8)
  }

  // MARK: File picker

  private func pick(
    _ picker: UIDocumentPickerViewController, _ result: @escaping FlutterResult,
    then done: @escaping ([URL]) -> Void
  ) {
    guard onPick == nil else {
      return result(FlutterError(code: "REQUEST_IN_PROGRESS", message: "File picker already open", details: nil))
    }
    let root = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
    guard let root else { return result(nil) }
    onPick = done
    picker.delegate = self
    root.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let done = onPick
    onPick = nil
    done?(urls)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    documentPicker(controller, didPickDocumentsAt: [])
  }
}

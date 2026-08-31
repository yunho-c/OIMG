import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

private struct PersistedDirectoryAccess {
  let path: String
  let bookmark: String

  var dictionary: [String: String] {
    ["path": path, "bookmark": bookmark]
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private let fileOpenChannelName = "oimg/file_open"
  private var fileOpenChannel: FlutterMethodChannel?
  private var pendingOpenRequests: [[String]] = []
  private var fileOpenChannelReady = false
  private let compressionServiceProvider = CompressionServiceProvider()
  private var securityScopedUrlsByPath: [String: URL] = [:]
  private var securityScopedDirectoryUrlsByPath: [String: URL] = [:]

  func attachFileOpenChannel(to controller: FlutterViewController) {
    guard fileOpenChannel == nil else {
      flushPendingOpenRequests()
      return
    }

    let channel = FlutterMethodChannel(
      name: fileOpenChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "App delegate unavailable", details: nil))
        return
      }

      if call.method == "ready" {
        self.fileOpenChannelReady = true
        self.flushPendingOpenRequests()
        result(nil)
      } else if call.method == "pickFiles" {
        result(
          self.presentOpenPanel(
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: true
          )
        )
      } else if call.method == "pickFolder" {
        result(
          self.presentOpenPanel(
            canChooseFiles: false,
            canChooseDirectories: true,
            allowsMultipleSelection: false
          )
        )
      } else if call.method == "pickFolderForPersistentAccess" {
        result(self.presentOpenPanelForPersistentFolderAccess())
      } else if call.method == "startAccessingSecurityScopedResource" {
        guard let bookmark = call.arguments as? String else {
          result(false)
          return
        }
        result(self.startAccessingSecurityScopedResource(bookmark: bookmark))
      } else if call.method == "ensureWritableDirectoryAccess" {
        guard let arguments = call.arguments as? [String: Any],
              let paths = arguments["paths"] as? [String]
        else {
          result(false)
          return
        }
        let accesses = arguments["accesses"] as? [[String: Any]] ?? []
        let bookmarks = accesses.compactMap { $0["bookmark"] as? String }
        result(
          self.ensureWritableDirectoryAccess(
            paths: paths,
            persistedBookmarks: bookmarks
          )
        )
      } else if call.method == "showInFileManager" {
        if let path = call.arguments as? String {
          self.showInFileManager(path: path)
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    fileOpenChannel = channel
    flushPendingOpenRequests()
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.servicesProvider = compressionServiceProvider
    NSUpdateDynamicServices()
    attachIfPossible()
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    retainSecurityScopedAccess(for: filenames.map(URL.init(fileURLWithPath:)))
    queueOpenRequest(filenames)
    attachIfPossible()
    sender.reply(toOpenOrPrint: .success)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    retainSecurityScopedAccess(for: urls)
    let filePaths = urls.filter(\.isFileURL).map(\.path)
    if !filePaths.isEmpty {
      queueOpenRequest(filePaths)
      attachIfPossible()
    }

    let nonFileUrls = urls.filter { !$0.isFileURL }
    if !nonFileUrls.isEmpty {
      super.application(application, open: nonFileUrls)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  private func attachIfPossible() {
    guard let controller = NSApp.windows
      .compactMap({ $0.contentViewController as? FlutterViewController })
      .first
    else {
      return
    }

    attachFileOpenChannel(to: controller)
  }

  private func queueOpenRequest(_ paths: [String]) {
    guard !paths.isEmpty else {
      return
    }

    pendingOpenRequests.append(paths)
    flushPendingOpenRequests()
  }

  private func flushPendingOpenRequests() {
    guard fileOpenChannelReady, let fileOpenChannel else {
      return
    }

    for paths in pendingOpenRequests {
      fileOpenChannel.invokeMethod("openFiles", arguments: paths)
    }
    pendingOpenRequests.removeAll()
  }

  private func retainSecurityScopedAccess(for urls: [URL]) {
    for selectedUrl in urls where selectedUrl.isFileURL {
      let canonicalUrl = canonicalFileUrl(selectedUrl)
      let path = canonicalUrl.path
      if securityScopedUrlsByPath[path] != nil {
        continue
      }

      if selectedUrl.startAccessingSecurityScopedResource() {
        securityScopedUrlsByPath[path] = selectedUrl
        if isDirectory(canonicalUrl) {
          securityScopedDirectoryUrlsByPath[path] = selectedUrl
        }
      }
    }
  }

  private func startAccessingSecurityScopedResource(bookmark: String) -> Bool {
    guard let data = Data(base64Encoded: bookmark) else {
      return false
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      let canonicalUrl = canonicalFileUrl(url)
      if securityScopedUrlsByPath[canonicalUrl.path] != nil {
        return true
      }
      guard url.startAccessingSecurityScopedResource() else {
        return false
      }

      securityScopedUrlsByPath[canonicalUrl.path] = url
      if isDirectory(canonicalUrl) {
        securityScopedDirectoryUrlsByPath[canonicalUrl.path] = url
      }
      return true
    } catch {
      return false
    }
  }

  private func ensureWritableDirectoryAccess(
    paths: [String],
    persistedBookmarks: [String]
  ) -> [String: Any] {
    var persistedAccesses = restoreDirectoryAccess(bookmarks: persistedBookmarks)
    var seenPaths = Set<String>()
    let directoryUrls = paths
      .filter { !$0.isEmpty }
      .map { canonicalFileUrl(URL(fileURLWithPath: $0, isDirectory: true)) }
      .filter { seenPaths.insert($0.path).inserted }

    for directoryUrl in directoryUrls {
      if hasSecurityScopedDirectoryAccess(to: directoryUrl) {
        addCoveringDirectoryAccess(
          for: directoryUrl,
          to: &persistedAccesses
        )
        continue
      }

      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.resolvesAliases = true
      panel.canCreateDirectories = false
      panel.treatsFilePackagesAsDirectories = false
      panel.directoryURL = directoryUrl.deletingLastPathComponent()
      panel.title = "Choose Save Folder"
      panel.message = "Choose \u{201c}\(directoryUrl.lastPathComponent)\u{201d} or a containing folder."
      panel.prompt = "Choose"

      guard panel.runModal() == .OK,
            let selectedUrl = panel.urls.first,
            selectedUrl.isFileURL
      else {
        return writableDirectoryAccessResult(
          didStartAccess: false,
          accesses: persistedAccesses
        )
      }

      retainSecurityScopedAccess(for: [selectedUrl])
      guard hasSecurityScopedDirectoryAccess(to: directoryUrl) else {
        return writableDirectoryAccessResult(
          didStartAccess: false,
          accesses: persistedAccesses
        )
      }
      addCoveringDirectoryAccess(for: directoryUrl, to: &persistedAccesses)
    }

    return writableDirectoryAccessResult(
      didStartAccess: true,
      accesses: persistedAccesses
    )
  }

  private func hasSecurityScopedDirectoryAccess(to directoryUrl: URL) -> Bool {
    coveringSecurityScopedDirectory(for: directoryUrl) != nil
  }

  private func coveringSecurityScopedDirectory(
    for directoryUrl: URL
  ) -> (path: String, url: URL)? {
    let directoryPath = canonicalFileUrl(directoryUrl).path
    return securityScopedDirectoryUrlsByPath
      .filter { entry in
        let scopedPath = entry.key
        return scopedPath == "/"
          || directoryPath == scopedPath
          || directoryPath.hasPrefix(scopedPath + "/")
      }
      .max { first, second in first.key.count < second.key.count }
      .map { (path: $0.key, url: $0.value) }
  }

  private func restoreDirectoryAccess(
    bookmarks: [String]
  ) -> [String: PersistedDirectoryAccess] {
    var accesses: [String: PersistedDirectoryAccess] = [:]
    for bookmark in bookmarks where !bookmark.isEmpty {
      guard let data = Data(base64Encoded: bookmark) else {
        continue
      }

      var isStale = false
      do {
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
        let canonicalUrl = canonicalFileUrl(url)
        guard isDirectory(canonicalUrl) else {
          continue
        }

        if securityScopedDirectoryUrlsByPath[canonicalUrl.path] == nil {
          guard url.startAccessingSecurityScopedResource() else {
            continue
          }
          securityScopedUrlsByPath[canonicalUrl.path] = url
          securityScopedDirectoryUrlsByPath[canonicalUrl.path] = url
        }

        let currentBookmark = isStale
          ? securityScopedBookmarkString(for: url) ?? bookmark
          : bookmark
        accesses[canonicalUrl.path] = PersistedDirectoryAccess(
          path: canonicalUrl.path,
          bookmark: currentBookmark
        )
      } catch {
        continue
      }
    }
    return accesses
  }

  private func addCoveringDirectoryAccess(
    for directoryUrl: URL,
    to accesses: inout [String: PersistedDirectoryAccess]
  ) {
    guard let coveringAccess = coveringSecurityScopedDirectory(for: directoryUrl),
          accesses[coveringAccess.path] == nil,
          let bookmark = securityScopedBookmarkString(for: coveringAccess.url)
    else {
      return
    }
    accesses[coveringAccess.path] = PersistedDirectoryAccess(
      path: coveringAccess.path,
      bookmark: bookmark
    )
  }

  private func writableDirectoryAccessResult(
    didStartAccess: Bool,
    accesses: [String: PersistedDirectoryAccess]
  ) -> [String: Any] {
    [
      "didStartAccess": didStartAccess,
      "accesses": accesses.values
        .sorted { $0.path < $1.path }
        .map(\.dictionary),
    ]
  }

  private func canonicalFileUrl(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func securityScopedBookmarkString(for url: URL) -> String? {
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func presentOpenPanelForPersistentFolderAccess() -> [String: String]? {
    let urls = presentOpenPanelUrls(
      canChooseFiles: false,
      canChooseDirectories: true,
      allowsMultipleSelection: false
    )
    guard let url = urls.first else {
      return nil
    }

    var result = ["path": url.path]
    if let bookmark = securityScopedBookmarkString(for: url) {
      result["bookmark"] = bookmark
    }
    return result
  }

  private func presentOpenPanel(
    canChooseFiles: Bool,
    canChooseDirectories: Bool,
    allowsMultipleSelection: Bool
  ) -> [String] {
    presentOpenPanelUrls(
      canChooseFiles: canChooseFiles,
      canChooseDirectories: canChooseDirectories,
      allowsMultipleSelection: allowsMultipleSelection
    )
    .map(\.path)
  }

  private func presentOpenPanelUrls(
    canChooseFiles: Bool,
    canChooseDirectories: Bool,
    allowsMultipleSelection: Bool
  ) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = canChooseFiles
    panel.canChooseDirectories = canChooseDirectories
    panel.allowsMultipleSelection = allowsMultipleSelection
    panel.resolvesAliases = true
    panel.canCreateDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    if canChooseFiles && !canChooseDirectories {
      if #available(macOS 11.0, *) {
        panel.allowedContentTypes = [.image]
      } else {
        panel.allowedFileTypes = ["public.image"]
      }
    }
    panel.title = canChooseDirectories ? "Open Folder" : "Open Files"
    panel.message = canChooseDirectories
      ? "Choose a folder to open in OIMG."
      : "Choose one or more image files to open in OIMG."

    guard panel.runModal() == .OK else {
      return []
    }

    retainSecurityScopedAccess(for: panel.urls)
    return panel.urls.filter(\.isFileURL)
  }

  private func showInFileManager(path: String) {
    guard !path.isEmpty else {
      return
    }

    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }

    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

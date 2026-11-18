import AppKit

/// "Show in Finder": a Finder window with the file or folder selected.
@MainActor func showInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

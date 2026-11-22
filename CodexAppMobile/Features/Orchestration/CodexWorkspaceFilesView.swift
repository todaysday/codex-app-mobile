import ImageIO
import PDFKit
import SwiftUI
import UIKit

struct CodexWorkspaceFilesView: View {
    @ObservedObject var client: AppServerClient
    let hostID: UUID
    let workspace: ProjectWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CodexWorkspaceDirectoryView(client: client, hostID: hostID, root: workspace.remotePath, path: workspace.remotePath)
                .navigationTitle(workspace.displayName)
                .navigationDestination(for: CodexWorkspaceFileLocation.self) { location in
                    switch location {
                    case .directory(let path):
                        CodexWorkspaceDirectoryView(client: client, hostID: hostID, root: workspace.remotePath, path: path)
                    case .file(let path):
                        CodexWorkspaceFilePreviewView(client: client, hostID: hostID, root: workspace.remotePath, path: path)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private enum CodexWorkspaceFileLocation: Hashable {
    case directory(String)
    case file(String)
}

private struct CodexWorkspaceDirectoryView: View {
    @ObservedObject var client: AppServerClient
    let hostID: UUID
    let root: String
    let path: String
    @State private var entries: [CodexRemoteFileEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var displayGeneration: Int?

    var body: some View {
        List {
            Section {
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
            } footer: {
                Text("Read-only previews up to 2 MiB. Symbolic links are not opened.")
            }
            if !client.isConnected(to: hostID) {
                Text("Connect to this host to browse files.").foregroundStyle(.secondary)
            } else if isLoading || displayGeneration != client.connectionGeneration {
                ProgressView("Loading files…")
            } else if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await reload() } }
                }
            } else if entries.isEmpty {
                Text("This directory is empty.").foregroundStyle(.secondary)
            } else {
                Section("Files") {
                    ForEach(entries) { entry in
                        if let child = try? CodexWorkspacePath.child(entry.fileName, of: path), entry.isDirectory || entry.isFile {
                            NavigationLink(value: entry.isDirectory ? CodexWorkspaceFileLocation.directory(child) : .file(child)) {
                                Label(entry.fileName, systemImage: entry.isDirectory ? "folder" : "doc")
                            }
                        } else {
                            Label(entry.fileName, systemImage: "questionmark.square.dashed").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(CodexWorkspacePath.name(path))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(path):\(client.connectionGeneration):\(client.state.rawValue)") { await reload() }
        .refreshable { await reload() }
    }

    @MainActor private func reload() async {
        let token = UUID()
        let generation = client.connectionGeneration
        loadID = token
        displayGeneration = generation
        entries = []
        errorMessage = nil
        isLoading = true
        defer { if loadID == token { isLoading = false } }
        guard client.isConnected(to: hostID) else { return }
        do {
            let result = try await client.workspaceReadDirectory(hostID: hostID, root: root, path: path)
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            entries = result
        } catch {
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct CodexWorkspaceFilePreviewView: View {
    @ObservedObject var client: AppServerClient
    let hostID: UUID
    let root: String
    let path: String
    @State private var preview: CodexRemoteFilePreview?
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var displayGeneration: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                if let preview, displayGeneration == client.connectionGeneration, client.isConnected(to: hostID) {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file)) · Read only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            Group {
                if !client.isConnected(to: hostID) {
                    ContentUnavailableView("Host disconnected", systemImage: "wifi.slash", description: Text("Reconnect to this host to load the preview."))
                } else if isLoading || displayGeneration != client.connectionGeneration {
                    ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Preview unavailable", systemImage: "doc.badge.ellipsis")
                    } description: { Text(errorMessage) } actions: {
                        Button("Retry") { Task { await reload() } }
                    }
                } else if let preview {
                    previewContent(preview)
                }
            }
        }
        .navigationTitle(CodexWorkspacePath.name(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(isLoading || !client.isConnected(to: hostID))
            }
        }
        .task(id: "\(path):\(client.connectionGeneration):\(client.state.rawValue)") { await reload() }
    }

    @ViewBuilder private func previewContent(_ preview: CodexRemoteFilePreview) -> some View {
        switch preview.content {
        case .text(let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "Empty file" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
        case .image:
            if let image {
                CodexWorkspaceImageView(image: image)
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text("The image format is invalid or unsupported."))
            }
        case .pdf(let data):
            CodexWorkspacePDFView(data: data)
        case .unsupported:
            ContentUnavailableView("Binary file", systemImage: "doc", description: Text("This file type does not have a preview. Text, images and PDF are supported."))
        }
    }

    @MainActor private func reload() async {
        let token = UUID()
        let generation = client.connectionGeneration
        loadID = token
        displayGeneration = generation
        preview = nil
        image = nil
        errorMessage = nil
        isLoading = true
        defer { if loadID == token { isLoading = false } }
        guard client.isConnected(to: hostID) else { return }
        do {
            let result = try await client.workspacePreviewFile(hostID: hostID, root: root, path: path)
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            if case .image(let data) = result.content {
                image = Self.thumbnail(data)
            }
            if case .pdf(let data) = result.content, PDFDocument(data: data) == nil {
                throw CodexWorkspaceToolError.invalidFileData
            }
            preview = result
        } catch {
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct CodexWorkspaceImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ImageScrollView {
        let view = ImageScrollView(frame: .zero)
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ImageScrollView, context: Context) {
        if view.imageView.image !== image { view.setImage(image) }
    }

    final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        private var lastLayoutSize = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            addSubview(imageView)
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
        }

        required init?(coder: NSCoder) { return nil }

        func setImage(_ image: UIImage) {
            imageView.image = image
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            lastLayoutSize = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
            if lastLayoutSize != bounds.size {
                lastLayoutSize = bounds.size
                let fit = min(min(bounds.width / image.size.width, bounds.height / image.size.height), 1)
                minimumZoomScale = fit
                maximumZoomScale = max(1, fit * 6)
                zoomScale = fit
            }
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        private func centerImage() {
            contentInset = UIEdgeInsets(
                top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2),
                bottom: 0, right: 0
            )
        }
    }
}

private struct CodexWorkspacePDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data {
            view.document = PDFDocument(data: data)
            context.coordinator.data = data
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    final class Coordinator {
        var data: Data
        init(data: Data) { self.data = data }
    }
}

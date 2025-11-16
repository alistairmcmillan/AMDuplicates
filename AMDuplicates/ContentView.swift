//
//  ContentView.swift
//  AMDuplicates
//
//  Created by Alistair McMillan on 15/11/2025.
//

import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import QuickLook

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let path: String
    let size: Int
    let modified: Date
    let kind: String
    let hash: String
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct ContentView: View {
    @State private var folderURL: URL?
    @State private var files: [FileItem] = []
    @State private var sortOrder: [KeyPathComparator<FileItem>] = [
        .init(\.name, order: .forward)
    ]
    @State private var selectedFileIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var filesProcessed = 0
    @State private var duplicateHashes: Set<String> = []
    @State private var hideUniqueFiles = false
    @State private var isDropTargeted = false
    @State private var quickLookURL: URL?
    @State private var scannedFolderURLs: Set<URL> = []
    
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            self.folderURL = panel.url
        }
    }
    
    private var displayedFiles: [FileItem] {
        hideUniqueFiles ? files.filter { duplicateHashes.contains($0.hash) } : files
    }
    
    private func computeFileHash(for url: URL) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            let chunkSize = 64 * 1024 // 64KB chunks
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            return "Error"
        }
    }
    
    private func makeFileItem(from url: URL) throws -> FileItem? {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        
        guard values.isDirectory != true else { return nil }
        
        let hashValue = computeFileHash(for: url)
        
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            path: url.deletingLastPathComponent().path,
            size: values.fileSize ?? 0,
            modified: values.contentModificationDate ?? .distantPast,
            kind: values.localizedTypeDescription ?? "Unknown",
            hash: hashValue
        )
    }
    
    private func scanFolder(_ folderURL: URL) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            var items: [FileItem] = []
            var lastUpdate = Date()
            
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
            
            guard let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return items
            }
            
            for case let fileURL as URL in enumerator {
                if let item = try? makeFileItem(from: fileURL) {
                    items.append(item)
                    
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > 0.1 {
                        await MainActor.run {
                            filesProcessed = items.count
                        }
                        lastUpdate = now
                    }
                }
            }
            
            return items
        }.value
    }
    
    private func recalculateDuplicates() {
        let hashCounts = Dictionary(grouping: files, by: \.hash)
            .mapValues(\.count)
        duplicateHashes = Set(hashCounts.filter { $0.value > 1 && $0.key != "Error" }.keys)
    }
    
    private func addFiles(_ newFiles: [FileItem]) {
        let existingPaths = Set(files.map { $0.url.path })
        let uniqueNewFiles = newFiles.filter { !existingPaths.contains($0.url.path) }
        files.append(contentsOf: uniqueNewFiles)
        files = files.sorted(using: sortOrder)
        recalculateDuplicates()
    }
    
    private func loadFiles(from folderURL: URL? = nil) {
        let targetURL = folderURL ?? self.folderURL
        guard let targetURL else { return }
        
        scannedFolderURLs.insert(targetURL)
        
        isLoading = true
        filesProcessed = 0
        
        Task {
            let newFileItems = await scanFolder(targetURL)
            addFiles(newFileItems)
            isLoading = false
        }
    }

    private func showInFinder(_ selectedIDs: Set<UUID>) {
        let urls = displayedFiles
            .filter { selectedIDs.contains($0.id) }
            .map { $0.url }
        
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func moveToTrash(_ selectedIDs: Set<UUID>) {
        let itemsToTrash = displayedFiles.filter { selectedIDs.contains($0.id) }
        
        for item in itemsToTrash {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        
        files.removeAll { itemsToTrash.contains($0) }
        recalculateDuplicates()
        selectedFileIDs.removeAll()
    }
    
    private func refreshAllFolders() {
        guard !scannedFolderURLs.isEmpty else { return }
        
        files.removeAll()
        duplicateHashes.removeAll()
        selectedFileIDs.removeAll()
        
        isLoading = true
        filesProcessed = 0
        
        Task {
            for folderURL in scannedFolderURLs {
                let newFiles = await scanFolder(folderURL)
                addFiles(newFiles)
            }
            isLoading = false
        }
    }
    
    private func clearAll() {
        files.removeAll()
        duplicateHashes.removeAll()
        selectedFileIDs.removeAll()
        hideUniqueFiles = false
        folderURL = nil
        scannedFolderURLs.removeAll()
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url = url, error == nil else { return }
            
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                DispatchQueue.main.async {
                    self.loadFiles(from: url)
                }
            }
        }
        
        return true
    }
    
    var body: some View {
        VStack {
            toolbarView
            
            Table(displayedFiles, selection: $selectedFileIDs, sortOrder: $sortOrder) {
                tableColumns
            }
            .onChange(of: sortOrder) {
                files = files.sorted(using: sortOrder)
            }
            .overlay {
                if isLoading {
                    loadingOverlay
                }
            }
            .quickLookPreview($quickLookURL)
            .onKeyPress(.space) {
                handleSpacePress()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                dropTargetIndicator
            }
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            contextMenuContent(for: selectedIDs)
        }
    }
    
    private var toolbarView: some View {
        HStack {
            Button("Choose Folder...") {
                pickFolder()
                loadFiles()
            }
            
            if !files.isEmpty {
                Button("Clear") {
                    clearAll()
                }
            }
            
            Spacer()
            
            if !duplicateHashes.isEmpty {
                Text("\(duplicateHashes.count) duplicate groups found")
                    .foregroundStyle(.red)
                    .font(.headline)
                
                Button(hideUniqueFiles ? "Show All" : "Show Duplicates Only") {
                    hideUniqueFiles.toggle()
                    selectedFileIDs.removeAll()
                }
            }
            
            Spacer()
            
            Button("Refresh") {
                refreshAllFolders()
            }
            .disabled(isLoading || scannedFolderURLs.isEmpty)
        }
    }
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                    .controlSize(.large)
                
                Text("Scanned \(filesProcessed) files...")
                    .foregroundStyle(.white)
                    .font(.headline)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }
    
    private var dropTargetIndicator: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 3)
            .padding(4)
    }
    
    @ViewBuilder
    private func contextMenuContent(for selectedIDs: Set<UUID>) -> some View {
        if !selectedIDs.isEmpty {
            Button("Show in Finder") {
                showInFinder(selectedIDs)
            }
            
            Divider()
            
            Button("Move to Trash") {
                moveToTrash(selectedIDs)
            }
        }
    }
    
    private func handleSpacePress() -> KeyPress.Result {
        if let selectedID = selectedFileIDs.first,
           let selectedFile = displayedFiles.first(where: { $0.id == selectedID }) {
            quickLookURL = selectedFile.url
            return .handled
        }
        return .ignored
    }
}

extension ContentView {
    
    @TableColumnBuilder<FileItem, KeyPathComparator<FileItem>>
    var tableColumns: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        duplicateIndicatorColumn
        nameColumn
        kindColumn
        dateModifiedColumn
        sizeColumn
        hashColumn
    }
    
    private var duplicateIndicatorColumn: some TableColumnContent<FileItem, Never> {
        TableColumn("") { item in
            if duplicateHashes.contains(item.hash) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("Duplicate file detected")
            }
        }
        .width(30)
    }
    
    private var nameColumn: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        TableColumn("Name", value: \.name) { item in
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                VStack {
                    Text(item.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    
    private var kindColumn: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        TableColumn("Kind", value: \.kind) { item in
            Text(item.kind)
                .foregroundStyle(.secondary)
        }
    }
    
    private var dateModifiedColumn: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        TableColumn("Date Modified", value: \.modified) { item in
            Text(item.modified, style: .date)
                .foregroundStyle(.secondary)
                .help(item.modified.formatted(date: .long, time: .shortened))
        }
    }
    
    private var sizeColumn: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        TableColumn("Size", value: \.size) { item in
            Text(ByteCountFormatter.string(
                fromByteCount: Int64(item.size),
                countStyle: .file
            ))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    
    private var hashColumn: some TableColumnContent<FileItem, KeyPathComparator<FileItem>> {
        TableColumn("Hash", value: \.hash) { item in
            Text(item.hash)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(duplicateHashes.contains(item.hash) ? .red : .secondary)
        }
    }
}

#Preview {
    ContentView()
}

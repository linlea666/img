import ReFrameEngine
import SwiftUI
import UniformTypeIdentifiers

/// 缩略图加载（原图只有 240×135，直接读即可）
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var cache: [URL: CGImage] = [:]

    func load(_ url: URL) -> CGImage? {
        if let hit = cache[url] { return hit }
        let image = try? ImageFiles.loadCGImage(url, maxPixelSize: 320)
        if cache.count > 2000 { cache.removeAll() }
        cache[url] = image
        return image
    }
}

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(state.items) { item in
                                ThumbnailCell(item: item, selected: state.selection.contains(item.id),
                                              focused: state.focusedID == item.id)
                                    .id(item.id)
                                    .onTapGesture(count: 2) {
                                        state.focusedID = item.id
                                        state.detailTab = .compare
                                    }
                                    .onTapGesture { state.click(item) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: state.batch.currentName) { _, _ in
                        if let name = state.batch.currentName, let item = state.items.first(where: { $0.name == name }) {
                            withAnimation { proxy.scrollTo(item.id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in state.addDropped([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("素材").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("全选") { state.selectAll() }.keyboardShortcut("a", modifiers: .command)
                Button("移除选中") { state.removeSelected() }.disabled(state.selection.isEmpty)
                Button("清空") { state.clearLibrary() }
                Divider()
                Button("修复选中的图") { state.startBatch(onlySelected: true) }
                    .disabled(state.selection.isEmpty || state.batch.isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .disabled(state.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let done = state.items.filter { $0.status == .done }.count
        var s = "\(state.items.count) 张，已修复 \(done) 张"
        if state.selection.count > 1 { s += "，选中 \(state.selection.count) 张" }
        return s
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("把图片或文件夹拖到这里").font(.title3)
            Text("原图只读不改，修复结果保存到另一个文件夹").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("打开图片…") { state.presentOpenFiles() }
                Button("打开文件夹…") { state.presentOpenFolder() }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct ThumbnailCell: View {
    let item: LibraryItem
    let selected: Bool
    let focused: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                statusBadge.padding(4)
            }
            Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .task(id: item.url) { image = await ThumbnailLoader.shared.load(item.url) }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
        case .processing:
            ProgressView().controlSize(.small)
        case .pending:
            EmptyView()
        }
    }
}

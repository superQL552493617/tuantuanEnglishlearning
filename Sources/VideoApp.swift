import SwiftUI
import AVKit
import UniformTypeIdentifiers

// 最低系统版本：iOS 17（Xcode 里 Deployment Target 设为 17.0 或更高）

// ============ 入口 ============
@main
struct VideoApp: App {
    @StateObject private var store = VideoStore()

    init() {
        // 播放类音频：静音键下有声音、AirPlay 投屏、锁屏后继续播放都需要
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // 做法二：从"文件"App 分享过来的视频（以后需要再用）
                .onOpenURL { url in store.importVideo(from: url) }
        }
    }
}

// ============ 视频存储（复制进 App 自己的目录） ============
final class VideoStore: ObservableObject {
    @Published var videos: [URL] = []
    @Published var isImporting = false
    @Published var message: String?

    private let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        videos = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func importVideo(from url: URL) {
        isImporting = true
        let folder = self.folder
        DispatchQueue.global(qos: .userInitiated).async {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            var dest = folder.appendingPathComponent(url.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {   // 重名自动加编号
                let name = url.deletingPathExtension().lastPathComponent
                dest = folder.appendingPathComponent("\(name)-\(n).\(url.pathExtension)")
                n += 1
            }
            do {
                try fm.copyItem(at: url, to: dest)      // 关键：复制，原视频删了也不影响
                if url.path.contains("/Inbox/") { try? fm.removeItem(at: url) }
                DispatchQueue.main.async {
                    self.reload()
                    self.isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.message = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: videos[i]) }
        reload()
    }
}

// ============ 播放模式 ============
enum PlayMode: String, CaseIterable, Identifiable {
    case listLoop = "列表循环"
    case singleLoop = "单个循环"
    case shuffle = "随机播放"
    var id: String { rawValue }
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let mode: PlayMode
}

// ============ 主界面 ============
struct ContentView: View {
    @EnvironmentObject var store: VideoStore
    @State private var showImporter = false
    @State private var request: PlayRequest?
    @State private var mode: PlayMode = .listLoop

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.videos, id: \.self) { url in
                    Button { play(from: url) } label: { VideoRow(url: url) }
                        .buttonStyle(.plain)
                }
                .onDelete(perform: store.delete)
            }
            .overlay {
                if store.videos.isEmpty {
                    Text("还没有视频\n点右上角 + 导入")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                if store.isImporting { ProgressView("导入中…") }
            }
            .navigationTitle("我的视频")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("全部播放") { play(from: nil) }
                        .disabled(store.videos.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            // 底部：选择播放模式
            .safeAreaInset(edge: .bottom) {
                Picker("播放模式", selection: $mode) {
                    ForEach(PlayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                .background(.bar)
            }
            // 做法一：点 + 打开"文件"选视频
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    urls.forEach { store.importVideo(from: $0) }
                }
            }
            .alert("提示", isPresented: Binding(
                get: { store.message != nil },
                set: { if !$0 { store.message = nil } })
            ) { Button("好") {} } message: { Text(store.message ?? "") }
            .fullScreenCover(item: $request) { req in
                PlayerView(urls: req.urls, mode: req.mode).ignoresSafeArea()
            }
        }
    }

    private var allowedTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie] +
        ["mkv", "avi", "flv", "rmvb", "wmv"].compactMap { UTType(filenameExtension: $0) }
    }

    // 点某个视频：从它开始；点"全部播放"：从头开始
    private func play(from url: URL?) {
        Task {
            var list = store.videos
            if let url, let i = list.firstIndex(of: url) {
                list = Array(list[i...]) + Array(list[..<i])
            }
            // 只保留系统能播放的，打不开的自动跳过
            var ok: [URL] = []
            for u in list {
                if await VideoRow.isPlayable(u) { ok.append(u) }
            }

            guard !ok.isEmpty else {
                store.message = "这个视频格式暂时播放不了（MKV、AVI 等需要第二版加入的播放内核）"
                return
            }
            switch mode {
            case .listLoop: break
            case .singleLoop: ok = [ok[0]]
            case .shuffle: ok.shuffle()
            }
            request = PlayRequest(urls: ok, mode: mode)
        }
    }
}

// ============ 列表每一行：缩略图 + 时长 + 大小 + 格式提示 ============
struct VideoRow: View {
    let url: URL
    @State private var thumb: UIImage?
    @State private var info = ""
    @State private var playable = true

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent).lineLimit(2)
                Text(playable ? info : "⚠️ 格式暂不支持")
                    .font(.caption)
                    .foregroundColor(playable ? .secondary : .orange)
            }
        }
        .task { await load() }
    }

    static func isPlayable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        playable = (try? await asset.load(.isPlayable)) ?? false

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var text = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if playable, let d = try? await asset.load(.duration), d.seconds.isFinite {
            let s = Int(d.seconds)
            let t = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                : String(format: "%d:%02d", s / 60, s % 60)
            text = t + " · " + text
        }
        info = text

        guard playable else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        if let cg = try? await gen.image(at: .zero).image {
            thumb = UIImage(cgImage: cg)
        }
    }
}

// ============ 播放器（自带 AirPlay 投屏按钮、画中画） ============
struct PlayerView: UIViewControllerRepresentable {
    let urls: [URL]
    let mode: PlayMode

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls, mode: mode) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = context.coordinator.player
        vc.allowsPictureInPicturePlayback = true
        context.coordinator.player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player.pause()
    }

    final class Coordinator: NSObject {
        let player: AVQueuePlayer
        let urls: [URL]
        let mode: PlayMode

        init(urls: [URL], mode: PlayMode) {
            self.urls = urls
            self.mode = mode
            player = AVQueuePlayer(items: urls.map { AVPlayerItem(url: $0) })
            player.allowsExternalPlayback = true   // AirPlay 投屏
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(didEnd(_:)),
                name: .AVPlayerItemDidPlayToEndTime, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // 一个视频播完，按模式往队尾补下一个
        @objc func didEnd(_ n: Notification) {
            guard let item = n.object as? AVPlayerItem,
                  let asset = item.asset as? AVURLAsset else { return }
            let next: URL
            switch mode {
            case .listLoop, .singleLoop: next = asset.url          // 播完的排回队尾
            case .shuffle: next = urls.randomElement() ?? asset.url // 随机挑一个
            }
            player.insert(AVPlayerItem(url: next), after: player.items().last)
        }
    }
}

import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

@main
struct PlayerApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}

func fmt(_ s: Double) -> String {
    let n = Int(max(0, s.isFinite ? s : 0))
    return String(format: "%d:%02d:%02d", n / 3600, n % 3600 / 60, n % 60)
}

// MARK: - Fotoğraflar'dan video alma
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in
            SentTransferredFile(m.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Movie(url: dest)
        }
    }
}

// MARK: - Açılış ekranı
struct RootView: View {
    @State private var url: URL?
    @State private var item: PhotosPickerItem?
    @State private var importing = false
    @State private var loading = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                PlayerScreen(url: url) { self.url = nil }.id(url)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 64))
                    Text("Oynatıcı").font(.largeTitle.bold())
                    Text("Bir video seç. Hiçbir şey internete yüklenmez.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if loading {
                        ProgressView().padding(.top, 20)
                    } else {
                        PhotosPicker(selection: $item, matching: .videos) {
                            label("Fotoğraflardan seç", filled: true)
                        }.padding(.top, 20)
                        Button { importing = true } label: {
                            label("Dosyalardan seç", filled: false)
                        }
                    }
                }.padding(32)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie]) { r in
            if case .success(let u) = r {
                _ = u.startAccessingSecurityScopedResource()
                url = u
            }
        }
        .onChange(of: item) { newItem in
            guard let newItem else { return }
            loading = true
            Task {
                if let m = try? await newItem.loadTransferable(type: Movie.self) { url = m.url }
                loading = false
                item = nil
            }
        }
    }

    func label(_ t: String, filled: Bool) -> some View {
        Text(t).font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(filled ? Color.white : Color.gray.opacity(0.24))
            .foregroundStyle(filled ? Color.black : Color.white)
            .clipShape(Capsule())
    }
}

// MARK: - Küçük resimler
final class ThumbStore: ObservableObject {
    @Published var images: [Int: UIImage] = [:]
    private let gen: AVAssetImageGenerator
    private var loading = Set<Int>()

    init(asset: AVAsset) {
        gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 135)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
    }

    func load(_ i: Int) {
        guard images[i] == nil, !loading.contains(i) else { return }
        loading.insert(i)
        Task {
            let t = CMTime(seconds: Double(i) * 10, preferredTimescale: 600)
            if let r = try? await gen.image(at: t) {
                let img = UIImage(cgImage: r.image)
                await MainActor.run { self.images[i] = img }
            }
        }
    }
}

// MARK: - Oynatıcı modeli
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    let thumbs: ThumbStore
    let name: String
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var isPlaying = false
    @Published var fast = false
    @Published var scrubbing = false
    @Published var fps = 0
    private var seeking = false
    private var pending = false
    private var target = 0.0
    private var wasPlaying = false
    private var obs: Any?

    init(url: URL) {
        let a = AVURLAsset(url: url)
        thumbs = ThumbStore(asset: a)
        name = url.lastPathComponent
        player.replaceCurrentItem(with: AVPlayerItem(asset: a))
        obs = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] t in
            guard let self, !self.scrubbing, !self.seeking else { return }
            self.time = t.seconds
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in self?.isPlaying = false }
        Task {
            let d = try? await a.load(.duration)
            let tr = try? await a.loadTracks(withMediaType: .video).first
            let f = try? await tr?.load(.nominalFrameRate)
            await MainActor.run {
                self.duration = d?.seconds ?? 0
                self.fps = Int((f ?? 0).rounded())
            }
        }
    }

    deinit {
        player.pause()
        if let obs { player.removeTimeObserver(obs) }
    }

    func play() {
        if duration > 0 && time >= duration - 0.1 { time = 0; seek(0) }
        player.defaultRate = fast ? 2 : 1
        player.play()
        isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { if isPlaying { pause() } else { play() } }

    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        player.defaultRate = on ? 2 : 1
        if on && !isPlaying { play() } else if isPlaying { player.rate = on ? 2 : 1 }
    }

    func jump(_ s: Double) {
        time = min(max(0, time + s), duration)
        seek(time)
    }
    func beginScrub() { wasPlaying = isPlaying; player.pause(); scrubbing = true }
    func scrub(_ d: Double) { time = min(max(0, time + d), duration); seek(time) }
    func endScrub() { scrubbing = false; if wasPlaying { play() } }

    private func seek(_ s: Double) {
        target = s
        if seeking { pending = true; return }
        run()
    }
    private func run() {
        seeking = true
        pending = false
        let t = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pending { self.run() } else { self.seeking = false }
            }
        }
    }
}

// MARK: - Video katmanı
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Film şeridi
struct ThumbView: View {
    @ObservedObject var store: ThumbStore
    let index: Int
    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let img = store.images[index] {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .clipped()
        .overlay(Rectangle().fill(Color.black).frame(width: 1), alignment: .trailing)
        .onAppear { store.load(index) }
    }
}

struct Filmstrip: View {
    @ObservedObject var m: PlayerModel
    @State private var lastX: CGFloat = 0
    @State private var hint = ""
    let pps = 9.95
    let sec = 10.0

    var fade: LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.1),
            .init(color: .black, location: 0.9),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width
                let half = w / 2 / pps
                let last = max(0, Int((max(m.duration, 0.1) - 0.05) / sec))
                let a = min(last, max(0, Int(floor((m.time - half) / sec))))
                let b = min(last, max(a, Int(floor((m.time + half) / sec))))
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Color.black
                        ForEach(a...b, id: \.self) { i in
                            ThumbView(store: m.thumbs, index: i)
                                .frame(width: sec * pps, height: 56)
                                .offset(x: w / 2 + (Double(i) * sec - m.time) * pps)
                        }
                    }.mask(fade)
                    RoundedRectangle(cornerRadius: 2).fill(Color.white)
                        .frame(width: 4, height: 56)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .offset(x: w / 2 - 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !m.scrubbing { m.beginScrub(); lastX = 0 }
                            let up = max(0, -v.translation.height)
                            let f = up > 110 ? 0.1 : (up > 40 ? 0.35 : 1.0)
                            hint = f == 1 ? "" : (f == 0.35 ? "Hassas sarma: ⅓ hız" : "Çok hassas sarma: 1/10 hız")
                            let dx = v.translation.width - lastX
                            lastX = v.translation.width
                            m.scrub(-Double(dx) * f / pps)
                        }
                        .onEnded { _ in hint = ""; m.endScrub() }
                )
            }.frame(height: 56)
            Text(hint).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white).frame(height: 22)
        }
    }
}

// MARK: - Oynatıcı ekranı
struct PlayerScreen: View {
    @StateObject private var m: PlayerModel
    let onClose: () -> Void
    @State private var showUI = true
    @State private var flash: String?
    @State private var flashID = 0

    init(url: URL, onClose: @escaping () -> Void) {
        _m = StateObject(wrappedValue: PlayerModel(url: url))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            stage.frame(maxHeight: .infinity)
            if showUI {
                controls.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: showUI)
    }

    var stage: some View {
        ZStack {
            VideoLayer(player: m.player)
            VStack {
                ZStack {
                    Text(m.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        .padding(.horizontal, 90)
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white).frame(width: 32, height: 32)
                                .background(Circle().fill(Color.black.opacity(0.4)))
                        }
                        Spacer()
                        pill(m.fast ? "2×" : (m.fps > 0 ? "\(m.fps) fps" : ""), strong: m.fast)
                    }
                }.padding(14)
                Spacer()
            }
            if let f = flash {
                Text(f).font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { m.jump(5); say("+5 sn") }
        .onTapGesture { showUI.toggle() }
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 60, perform: {
            m.setFast(true)
        }, onPressingChanged: { pressing in
            if !pressing { m.setFast(false) }
        })
    }

    @ViewBuilder
    func pill(_ t: String, strong: Bool) -> some View {
        if !t.isEmpty {
            Text(t).font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(strong ? Color.black : Color.white.opacity(0.7))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(strong ? Color.white : Color.black.opacity(0.4)))
        }
    }

    var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fmt(m.time)).fontWeight(.semibold)
                Spacer()
                Text(fmt(m.duration)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13).monospacedDigit())
            .padding(.horizontal, 22).padding(.bottom, 10)
            Filmstrip(m: m).padding(.horizontal, 16)
            HStack(spacing: 6) {
                ForEach([-60, -30, -5], id: \.self) { skip($0) }
                Button { m.toggle() } label: {
                    Image(systemName: m.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26)).foregroundStyle(.black)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(Press()).padding(.horizontal, 8)
                ForEach([5, 30, 60], id: \.self) { skip($0) }
            }
            .padding(.top, 2).padding(.bottom, 6)
        }
        .padding(.top, 16)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color(white: 0.11)).ignoresSafeArea(edges: .bottom)
        )
    }

    func skip(_ s: Int) -> some View {
        Button {
            m.jump(Double(s))
            say(s > 0 ? "+\(s) sn" : "−\(-s) sn")
        } label: {
            Text(s > 0 ? "+\(s)" : "−\(-s)")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 38)
                .background(Capsule().fill(Color.gray.opacity(0.24)))
        }
        .buttonStyle(Press())
    }

    func say(_ s: String) {
        flash = s
        flashID += 1
        let id = flashID
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if id == flashID { flash = nil }
        }
    }
}

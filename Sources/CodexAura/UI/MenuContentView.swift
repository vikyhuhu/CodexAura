import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            themeListHeader
            ScrollView {
                themeGrid
                    .padding(.horizontal, 2)
            }
            .frame(height: gridHeight)
            .scrollIndicators(.visible, axes: .vertical)
            if model.activeThemeID != nil { tuning }
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            model.reloadThemes()
            // Codex may have been quit/restarted behind our back — re-check on
            // every menu open instead of showing a stale "ready" forever.
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(model.statusLine)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if model.busy { ProgressView().scaleEffect(0.6) }
        }
    }

    private var statusIcon: String {
        switch model.codexState {
        case .ready: return "checkmark.circle.fill"
        case .notInstalled: return "exclamationmark.triangle.fill"
        case .signatureInvalid: return "exclamationmark.shield.fill"
        case .notRunning: return "moon.circle"
        case .runningNoCDP: return "arrow.clockwise.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch model.codexState {
        case .ready: return .green
        case .notInstalled, .signatureInvalid: return .red
        default: return .orange
        }
    }

    private var themeGrid: some View {
        Group {
            if model.themes.isEmpty {
                Text("还没有主题。点下方「导入图片」把喜欢的图变成主题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.themes) { theme in
                        ThemeCardView(theme: theme, active: theme.id == model.activeThemeID)
                            .onTapGesture { Task { await model.apply(theme) } }
                            .contextMenu {
                                Button("导出主题包…") { model.exportPack(theme) }
                                Button("删除", role: .destructive) { model.deleteTheme(theme) }
                            }
                    }
                }
            }
        }
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("暗角").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: $model.dim, in: 0...0.8) { editing in
                    if !editing { model.persistTuning() }
                }
            }
            HStack {
                Text("模糊").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: $model.blur, in: 0...30) { editing in
                    if !editing { model.persistTuning() }
                }
            }
            Toggle("边界线", isOn: $model.bordered)
                .toggleStyle(.switch)
                .controlSize(.small)
            TextField("签名（显示在标题下方）", text: $model.tagline)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if model.codexState == .runningNoCDP {
                Button("重启 Codex 以启用换肤") { Task { await model.restartCodex() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            HStack {
                Button("导入图片…") { Task { await model.importImage() } }
                Button("导入主题包…") { Task { await model.importPack() } }
            }
            .controlSize(.small)
            HStack {
                Button("导入 DS 预设") { model.importDreamSkinPresets() }
                Spacer()
                // Also offered in `.ready` with no active theme: a previous run
                // may have left skinned pages behind that need cleaning.
                if model.activeThemeID != nil || model.codexState == .ready {
                    Button("还原官方外观") { Task { await model.restore() } }
                }
            }
            .controlSize(.small)
            HStack {
                Button("刷新状态") { Task { await model.refresh() } }
                Spacer()
                Button("退出 CodexAura") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }

    private var themeListHeader: some View {
        HStack {
            Text("主题")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// MenuBarExtra 的窗口按内容自适应，ScrollView 没有固有高度会塌缩，
    /// 所以按行数显式计算高度（每行卡片约 108pt，最多 380pt 后滚动）。
    private var gridHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(model.themes.count) / 2.0)))
        return min(380, CGFloat(rows) * 108 + 8)
    }
}

struct ThemeCardView: View {
    let theme: Theme
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
                .overlay(alignment: .topTrailing) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(4)
                    }
                }
            Text(theme.name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = theme.thumbnailURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(height: 72)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
                .frame(height: 72)
                .overlay { Image(systemName: "photo") }
        }
    }
}

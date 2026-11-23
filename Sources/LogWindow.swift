import SwiftUI
import AppKit

enum LogFilter: String, CaseIterable, Identifiable {
    case all = "Tümü", info = "Bilgi", warning = "Uyarı", error = "Hata"
    var id: String { rawValue }

    func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all: return true
        case .info: return level == .info
        case .warning: return level == .warning
        case .error: return level == .error
        }
    }
}

/// Yalnızca pencere açıkken var olur; en fazla 500 satır tutar.
final class LogViewModel: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published var filter: LogFilter = .all
    @Published var autoScroll = true

    var filtered: [LogEntry] { filter == .all ? entries : entries.filter { filter.matches($0.level) } }

    func set(_ list: [LogEntry]) { entries = Array(list.suffix(Log.maxViewerLines)) }

    func append(_ e: LogEntry) {
        entries.append(e)
        if entries.count > Log.maxViewerLines { entries.removeFirst(entries.count - Log.maxViewerLines) }
    }

    func clear() { entries.removeAll() }
}

struct LogView: View {
    @ObservedObject var model: LogViewModel
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LogToolbar(model: model, onCopy: onCopy, onClear: onClear)
            Divider()
            LogList(model: model)
            Divider()
            LogFooter(count: model.filtered.count)
        }
        .frame(minWidth: 560, minHeight: 300)
        .preferredColorScheme(.dark)
    }
}

private struct LogToolbar: View {
    @ObservedObject var model: LogViewModel
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.filter) {
                ForEach(LogFilter.allCases) { (f: LogFilter) in
                    Text(L(f.rawValue)).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            Spacer()
            Toggle(L("Otomatik kaydır"), isOn: $model.autoScroll).toggleStyle(.checkbox)
            Button(action: onCopy) { Label(L("Kopyala"), systemImage: "doc.on.doc") }
            Button(action: onClear) { Label(L("Temizle"), systemImage: "trash") }
        }
        .padding(10)
    }
}

private struct LogList: View {
    @ObservedObject var model: LogViewModel

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            LogScroll(model: model, proxy: proxy)
        }
        .background(Color.black.opacity(0.25))
    }
}

private struct LogScroll: View {
    @ObservedObject var model: LogViewModel
    let proxy: ScrollViewProxy

    private func scrollToEnd() {
        if let last = model.filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    var body: some View {
        let rows: [LogEntry] = model.filtered
        let lastID: Int = model.entries.last?.id ?? -1
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { (e: LogEntry) in
                    LogRow(entry: e).id(e.id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: lastID) { _ in
            if model.autoScroll { scrollToEnd() }
        }
        .onAppear { scrollToEnd() }
    }
}

private struct LogFooter: View {
    let count: Int
    var body: some View {
        let path: String = Log.fileURL.path
        let text: String = L("%@ satır · %@", count, path)
        return HStack {
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Finder'da Göster", action: { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) })
                .buttonStyle(.link)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        let c: Color = color
        let time: String = String(entry.time.suffix(8))
        let messageColor: Color = entry.level == .info ? Color.primary : c
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).foregroundColor(.secondary)
            Text(entry.level.rawValue)
                .foregroundColor(c)
                .frame(width: 44, alignment: .leading)
            Text(entry.message)
                .foregroundColor(messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var color: Color {
        switch entry.level {
        case .info: return Color(red: 0.55, green: 0.75, blue: 1.0)
        case .warning: return .orange
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }
}

/// Günlük penceresi: ilk açılışta oluşturulur, kapanınca tamamen serbest bırakılır.
final class LogWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: LogViewModel?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let m = LogViewModel()
        model = m
        let view = LogView(model: m, onCopy: { [weak m] in
            guard let m = m else { return }
            let text = m.filtered.map { $0.line }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }, onClear: { [weak m] in
            Log.clear()
            m?.clear()
        })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.title = L("Workstation – Günlük")
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: view)
        w.delegate = self
        w.center()
        window = w

        Log.loadTail { [weak m] entries in m?.set(entries) }
        Log.setObserver { [weak m] entry in m?.append(entry) }

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Log.setObserver(nil)
        window?.contentView = nil
        window?.delegate = nil
        window = nil
        model = nil
    }
}

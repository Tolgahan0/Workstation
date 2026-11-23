import Foundation

/// Küçük yardımcılar: harici komut çalıştırma ve günlükleme.
/// (Yalnızca Foundation kullanır.)

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

/// Arka plan okuyucularının yazdığı veriyi tutar (erişim DispatchGroup ile sıralanır).
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {
    /// Bir komutu çalıştırır, çıktısını toplar ve `timeout` saniye içinde bitmezse sonlandırır.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 15,
                    environment: [String: String]? = nil, currentDirectory: String? = nil) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return CommandResult(status: 127, stdout: "", stderr: L("Çalıştırılabilir dosya bulunamadı: %@", launchPath), timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let env = environment { process.environment = env }
        if let cwd = currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Çıktıyı arka planda oku (büyük çıktılarda pipe tamponunun dolup kilitlenmesini önler).
        let outBox = DataBox()
        let errBox = DataBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            // Pipe'ları kapat ki okuyucu iş parçacıkları bitsin.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            readGroup.wait()
            return CommandResult(status: 126, stdout: "", stderr: L("Başlatılamadı: %@", error.localizedDescription), timedOut: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        _ = readGroup.wait(timeout: .now() + 3)
        // Dosya tanıtıcılarını açıkça kapat (sızıntı olmasın).
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        let out = String(data: outBox.data, encoding: .utf8) ?? ""
        let err = String(data: errBox.data, encoding: .utf8) ?? ""
        let status: Int32 = timedOut ? -1 : process.terminationStatus
        return CommandResult(status: status, stdout: out, stderr: err, timedOut: timedOut)
    }
}

enum LogLevel: String {
    case info = "INFO"
    case warning = "UYARI"
    case error = "HATA"
}

/// Günlük görüntüleyicide gösterilen tek satır.
struct LogEntry: Identifiable, Equatable {
    let id: Int
    let time: String
    let level: LogLevel
    let message: String

    var line: String { "\(time) [\(level.rawValue)] \(message)" }
}

/// Dosya tabanlı günlük. Bellekte satır TUTMAZ; görüntüleyici açıkken yalnızca son 500 satırı
/// dosyadan okur ve canlı satırları gözlemci ile alır. Dosya 1 MB'ı geçince .1 olarak döndürülür.
enum Log {
    static let maxFileBytes: UInt64 = 1_000_000
    static let maxViewerLines = 500

    static let fileURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Workstation.log")
    }()

    private static let queue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.log", qos: .utility)
    private static var observer: ((LogEntry) -> Void)?
    private static var nextID = 0

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ message: String) { write(.info, message) }
    static func warn(_ message: String) { write(.warning, message) }
    static func error(_ message: String) { write(.error, message) }

    /// Görüntüleyici açıkken canlı satırlar için gözlemci (ana kuyrukta çağrılır). nil = kapat.
    static func setObserver(_ handler: ((LogEntry) -> Void)?) {
        queue.async { observer = handler }
    }

    private static func write(_ level: LogLevel, _ message: String) {
        NSLog("[Workstation] %@: %@", level.rawValue, message)
        let now = Date()
        queue.async {
            let time = formatter.string(from: now)
            let entry = LogEntry(id: makeID(), time: time, level: level, message: message)
            append(entry.line + "\n")
            if let obs = observer {
                DispatchQueue.main.async { obs(entry) }
            }
        }
    }

    private static func makeID() -> Int {
        nextID += 1
        return nextID
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            let size = handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            if size + UInt64(data.count) > maxFileBytes { rotate() }
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static func rotate() {
        let old = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    /// "yyyy-MM-dd HH:mm:ss [SEVİYE] mesaj" satırını ayrıştırır.
    static func parse(line: String, id: Int) -> LogEntry? {
        guard line.count > 21 else { return nil }
        let time = String(line.prefix(19))
        let rest = line.dropFirst(20)
        guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else {
            return LogEntry(id: id, time: time, level: .info, message: String(rest))
        }
        let levelText = String(rest[rest.index(after: rest.startIndex)..<close])
        let level = LogLevel(rawValue: levelText) ?? .info
        let msgStart = rest.index(after: close)
        let message = rest[msgStart...].trimmingCharacters(in: .whitespaces)
        return LogEntry(id: id, time: time, level: level, message: message)
    }

    /// Dosyanın sonundan en fazla `maxLines` satır okur (en fazla ~256 KB okunur). Tamamlanınca ana kuyrukta döner.
    static func loadTail(maxLines: Int = maxViewerLines, completion: @escaping ([LogEntry]) -> Void) {
        queue.async {
            var entries: [LogEntry] = []
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                let size = handle.seekToEndOfFile()
                let chunk: UInt64 = 256 * 1024
                handle.seek(toFileOffset: size > chunk ? size - chunk : 0)
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                let text = String(decoding: data, as: UTF8.self)
                var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                if size > chunk, !lines.isEmpty { lines.removeFirst() } // yarım satır
                for line in lines.suffix(maxLines) {
                    if let e = parse(line: String(line), id: makeID()) { entries.append(e) }
                }
            }
            let result = entries
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func clear() {
        queue.async {
            try? Data().write(to: fileURL)
            try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("1"))
        }
    }
}

import Foundation

/// Kaydırıcıdan gelen parlaklık değerlerini birleştirir:
///  - sürükleme sırasında monitör başına yalnızca EN SON değer gönderilir,
///  - DDC için en fazla ~150 ms'de bir, yazılım (gama) için ~33 ms'de bir (akıcı),
///  - bırakınca son değer hemen yazılır,
///  - aynı değer tekrar gönderilmez,
///  - tüm yazmalar tek bir seri arka plan kuyruğunda yapılır (ana iş parçacığı asla beklemez).
final class BrightnessCoalescer {
    typealias Apply = (_ key: String, _ value: Double) -> BrightnessMethod
    typealias IntervalProvider = (_ key: String) -> TimeInterval

    static let ddcInterval: TimeInterval = 0.15
    static let softwareInterval: TimeInterval = 0.033

    private let queue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.brightness", qos: .userInitiated)
    private let apply: Apply
    private let interval: IntervalProvider

    // Yalnızca `queue` üzerinde erişilir.
    private var pending: [String: Double] = [:]
    private var scheduled: Set<String> = []
    private var lastSent: [String: Double] = [:]
    private var lastSentAt: [String: Date] = [:]

    /// Son yazmanın sonucu (ana kuyrukta).
    var onResult: ((String, BrightnessMethod) -> Void)?

    init(interval: @escaping IntervalProvider, apply: @escaping Apply) {
        self.interval = interval
        self.apply = apply
    }

    /// - Parameter final: true ise (kaydırıcı bırakıldı) bekleyen değer hemen yazılır.
    func submit(key: String, value: Double, final: Bool) {
        let v = (value * 10).rounded() / 10   // 0.1 hassasiyet: gereksiz tekrarları ele
        queue.async {
            self.pending[key] = v
            if final {
                self.flush(key)
                return
            }
            guard !self.scheduled.contains(key) else { return }
            let elapsed = Date().timeIntervalSince(self.lastSentAt[key] ?? .distantPast)
            let wait = max(0, self.interval(key) - elapsed)
            self.scheduled.insert(key)
            self.queue.asyncAfter(deadline: .now() + wait) {
                self.scheduled.remove(key)
                self.flush(key)
            }
        }
    }

    /// Önbelleği unut (ör. monitör yeniden tarandığında aynı değerin tekrar yazılabilmesi için).
    func reset(key: String? = nil) {
        queue.async {
            if let k = key { self.lastSent[k] = nil } else { self.lastSent.removeAll() }
        }
    }

    private func flush(_ key: String) {
        guard let v = pending.removeValue(forKey: key) else { return }
        if lastSent[key] == v { return }
        let method = apply(key, v)
        lastSent[key] = v
        lastSentAt[key] = Date()
        if let cb = onResult {
            DispatchQueue.main.async { cb(key, method) }
        }
    }
}

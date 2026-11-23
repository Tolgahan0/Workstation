import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Remote modunda Mac mini'nin varsayılan ses çıkışını sessize alır, Masaüstü'nde geri yükler.
/// Yalnızca BİZİM sessize aldığımız durumu geri yükler (kullanıcı zaten sessize aldıysa dokunmaz).
/// Cihaz "mute" özelliğini desteklemiyorsa (ör. bazı HDMI/DisplayPort çıkışları) ses seviyesi 0 yapılır
/// ve önceki seviye geri yüklenir.
final class AudioControl {
    static let settingKey = "muteAudioInRemote"
    private static let stateKey = "audioMuteState"

    struct SavedState: Codable, Equatable {
        var deviceID: UInt32
        /// "mute" veya "volume"
        var method: String
        var previousVolumes: [UInt32: Float] = [:]
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    private let queue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.audio", qos: .utility)

    private var saved: SavedState? {
        get {
            guard let d = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
            return try? JSONDecoder().decode(SavedState.self, from: d)
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(d, forKey: Self.stateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.stateKey)
            }
        }
    }

    func muteForRemote() {
        queue.async { self.muteSync() }
    }

    func restoreIfNeeded() {
        queue.async { self.restoreSync() }
    }

    #if os(macOS)
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private func settable(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var s: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
    }

    private func getUInt32(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var a = addr
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setUInt32(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var a = addr
        var v = value
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private func getFloat(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress) -> Float? {
        var a = addr
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setFloat(_ dev: AudioDeviceID, _ addr: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var a = addr
        var v = Float32(value)
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private func muteAddr() -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    private func volumeAddr(_ element: UInt32) -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
    }

    private func muteSync() {
        guard saved == nil else { return }   // zaten bizim tarafımızdan sessiz
        guard let dev = defaultOutputDevice() else { Log.warn("Ses: varsayılan çıkış bulunamadı"); return }
        let m = muteAddr()
        if settable(dev, m) {
            if getUInt32(dev, m) == 1 { Log.info("Ses: çıkış zaten sessiz, dokunulmadı"); return }
            if setUInt32(dev, m, 1) {
                saved = SavedState(deviceID: dev, method: "mute")
                Log.info("Ses: Remote için çıkış sessize alındı (cihaz \(dev))")
            } else {
                Log.warn("Ses: sessize alma başarısız")
            }
            return
        }
        // Mute yok: kanal seviyelerini 0 yap (ana öğe + 1…2).
        var previous: [UInt32: Float] = [:]
        for el in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            let a = volumeAddr(el)
            guard settable(dev, a), let v = getFloat(dev, a) else { continue }
            if setFloat(dev, a, 0) { previous[el] = v }
        }
        if previous.isEmpty {
            Log.warn("Ses: çıkış cihazı sessize alma / ses seviyesini desteklemiyor (cihaz \(dev))")
        } else {
            saved = SavedState(deviceID: dev, method: "volume", previousVolumes: previous)
            Log.info("Ses: Remote için ses seviyesi 0 yapıldı (cihaz \(dev))")
        }
    }

    private func restoreSync() {
        guard let s = saved else { return }
        saved = nil
        let dev = AudioDeviceID(s.deviceID)
        if s.method == "mute" {
            if setUInt32(dev, muteAddr(), 0) { Log.info("Ses: geri açıldı") } else { Log.warn("Ses: geri açma başarısız (cihaz değişmiş olabilir)") }
        } else {
            var ok = false
            for (el, v) in s.previousVolumes { ok = setFloat(dev, volumeAddr(el), v) || ok }
            Log.info(ok ? "Ses: önceki seviye geri yüklendi" : "Ses: seviye geri yüklenemedi (cihaz değişmiş olabilir)")
        }
    }
    #else
    private func muteSync() {}
    private func restoreSync() { saved = nil }
    #endif
}

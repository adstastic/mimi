import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static func validSelection(_ selectedID: String?, in devices: [AudioInputDevice]) -> String? {
        guard let selectedID, !selectedID.isEmpty else { return nil }
        return devices.contains { $0.id == selectedID } ? selectedID : nil
    }

    static func available() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
            else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func deviceID(for uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) == uid }
    }

    static func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard dataStatus == noErr else { return [] }
        return devices
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize >= MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedValue: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &unmanagedValue)
        guard status == noErr, let value = unmanagedValue?.takeUnretainedValue() else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}

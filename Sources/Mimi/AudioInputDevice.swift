import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    enum Transport: Hashable, Sendable {
        case builtIn
        case bluetooth
        case other
    }

    let id: String
    let name: String
    var transport: Transport = .other

    static func validSelection(_ selectedID: String?, in devices: [AudioInputDevice]) -> String? {
        guard let selectedID, !selectedID.isEmpty else { return nil }
        return devices.contains { $0.id == selectedID } ? selectedID : nil
    }

    static func automaticSelection(
        defaultInputDeviceID: String?,
        in devices: [AudioInputDevice]
    ) -> String? {
        guard let defaultInputDeviceID,
              let defaultDevice = devices.first(where: { $0.id == defaultInputDeviceID })
        else { return defaultInputDeviceID }
        guard defaultDevice.transport == .bluetooth else { return defaultInputDeviceID }
        return devices.first(where: { $0.transport == .builtIn })?.id ?? defaultInputDeviceID
    }

    static func resolvedSelection(
        _ selectedID: String?,
        defaultInputDeviceID: String?,
        in devices: [AudioInputDevice]
    ) -> String? {
        guard selectedID == nil || selectedID?.isEmpty == true else { return selectedID }
        return automaticSelection(defaultInputDeviceID: defaultInputDeviceID, in: devices)
    }

    static func resolvedSelection(_ selectedID: String?) -> String? {
        let devices = available()
        return resolvedSelection(
            selectedID,
            defaultInputDeviceID: defaultInputDeviceUID(),
            in: devices
        )
    }

    static func available() -> [AudioInputDevice] {
        selectable(allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
            else { return nil }
            return AudioInputDevice(
                id: uid,
                name: name,
                transport: transport(deviceID)
            )
        })
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func selectable(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.filter { !$0.id.hasPrefix(SystemAudioTap.aggregateUIDPrefix) }
    }

    static func deviceID(for uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) == uid }
    }

    static func defaultInputDeviceUID() -> String? {
        guard let deviceID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    static func shouldUseSystemAudioReference(outputTransport: Transport) -> Bool {
        outputTransport != .bluetooth
    }

    static func shouldUseSystemAudioReferenceForDefaultOutput() -> Bool {
        guard let deviceID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) else { return true }
        return shouldUseSystemAudioReference(outputTransport: transport(deviceID))
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        return status == noErr && deviceID != 0 ? deviceID : nil
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

    private static func transport(_ deviceID: AudioDeviceID) -> Transport {
        switch uint32Property(kAudioDevicePropertyTransportType, deviceID: deviceID) {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        default:
            return .other
        }
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
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

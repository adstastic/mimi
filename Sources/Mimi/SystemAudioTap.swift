import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class SystemAudioTap {
    static let aggregateUIDPrefix = "com.ad1.mimi.echo-reference."

    enum TapError: LocalizedError {
        case createTap(OSStatus)
        case readFormat(OSStatus)
        case invalidFormat
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case startDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .createTap(let status): "Could not create system audio tap (\(status))."
            case .readFormat(let status): "Could not read system audio format (\(status))."
            case .invalidFormat: "System audio tap returned an unsupported format."
            case .createAggregate(let status): "Could not create system audio device (\(status))."
            case .createIOProc(let status): "Could not observe system audio (\(status))."
            case .startDevice(let status): "Could not start system audio observation (\(status))."
            }
        }
    }

    typealias SampleHandler = (_ samples: [Float], _ sampleRate: Int32, _ hostTime: UInt64) -> Void

    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func start(on queue: DispatchQueue, sampleHandler: @escaping SampleHandler) throws {
        stop()

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Mimi Echo Reference"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }
        processTapID = tapID

        do {
            var streamDescription = try readTapFormat(tapID)
            guard let format = AVAudioFormat(streamDescription: &streamDescription),
                  format.commonFormat == .pcmFormatFloat32,
                  format.channelCount == 1,
                  format.sampleRate >= 8_000,
                  format.sampleRate <= 384_000 else {
                throw TapError.invalidFormat
            }

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Mimi Echo Reference",
                kAudioAggregateDeviceUIDKey: "\(Self.aggregateUIDPrefix)\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]

            status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            )
            guard status == noErr else { throw TapError.createAggregate(status) }

            status = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                queue
            ) { _, inputData, inputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inputData,
                    deallocator: nil
                ), let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                sampleHandler(
                    Array(UnsafeBufferPointer(start: channel, count: count)),
                    Int32(format.sampleRate.rounded()),
                    inputTime.pointee.mHostTime
                )
            }
            guard status == noErr else { throw TapError.createIOProc(status) }

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else { throw TapError.startDevice(status) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if processTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.readFormat(status) }
        return format
    }
}

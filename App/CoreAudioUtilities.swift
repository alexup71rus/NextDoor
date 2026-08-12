import CoreAudio
import Foundation

enum CoreAudioUtilities {
    static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ),
            operation: "Не удалось определить аудиовыход"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioFailure(operation: "В macOS не выбран аудиовыход", status: kAudioHardwareBadDeviceError)
        }

        return deviceID
    }

    static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)

        try check(
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &size,
                    pointer
                )
            },
            operation: "Не удалось прочитать параметры аудиоустройства"
        )

        return value as String
    }

    static func doubleProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64.zero
        var size = UInt32(MemoryLayout<Float64>.size)

        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: "Не удалось прочитать частоту дискретизации аудиоустройства"
        )

        return value
    }

    static func audioFormat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: "Не удалось прочитать формат аудиопотока"
        )

        guard size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw CoreAudioDataError.invalidAudioFormat
        }

        return value
    }

    static func streamIDs(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "Не удалось прочитать список аудиопотоков"
        )

        let stride = UInt32(MemoryLayout<AudioObjectID>.size)
        guard size > 0, size % stride == 0 else {
            throw CoreAudioDataError.invalidStreamList
        }

        var streamIDs = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size / stride)
        )
        try streamIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CoreAudioDataError.invalidStreamList
            }
            try check(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    baseAddress
                ),
                operation: "Не удалось прочитать список аудиопотоков"
            )
        }

        return streamIDs
    }

    static func createPrivateAggregateDevice(
        outputDeviceUID: String,
        tapUID: String
    ) throws -> AudioObjectID {
        let aggregateUID = "com.aleksandr.NextDoor.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NextDoor Private Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID,
                    kAudioSubDeviceInputChannelsKey: 0
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID),
            operation: "Не удалось создать безопасный аудиомаршрут"
        )
        return aggregateDeviceID
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioFailure(operation: operation, status: status)
        }
    }
}

private enum CoreAudioDataError: LocalizedError {
    case invalidAudioFormat
    case invalidStreamList

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "macOS вернула некорректный формат аудиопотока"
        case .invalidStreamList:
            "macOS вернула некорректный список аудиопотоков"
        }
    }
}

private struct CoreAudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) (\(Self.readableStatus(status)))"
    }

    private static func readableStatus(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let code = String(bytes: bytes, encoding: .ascii) {
            return "\(code), \(status)"
        }

        return String(status)
    }
}

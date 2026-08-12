import CoreAudio
import Darwin
import Foundation
import Synchronization
import os

@MainActor
final class AudioEffectController {
    private var processor: NeighborDSP?
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var running = false
    private let logger = Logger(subsystem: "com.aleksandr.NextDoor", category: "DSP")

    var isRunning: Bool {
        running
    }

    func start(parameters: EffectParameters) throws {
        guard !running else {
            apply(parameters)
            return
        }

        stop()

        do {
            let outputDeviceID = try CoreAudioUtilities.defaultOutputDeviceID()
            let outputDeviceUID = try CoreAudioUtilities.stringProperty(
                objectID: outputDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            )
            let description = CATapDescription(
                excludingProcesses: [],
                deviceUID: outputDeviceUID,
                stream: 0
            )
            description.name = "NextDoor System Audio"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.aleksandr.NextDoor"]
            description.isProcessRestoreEnabled = true

            try CoreAudioUtilities.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "Не удалось подключиться к системному звуку"
            )
            tapDescription = description

            let tapUID = try CoreAudioUtilities.stringProperty(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )

            aggregateDeviceID = try CoreAudioUtilities.createPrivateAggregateDevice(
                outputDeviceUID: outputDeviceUID,
                tapUID: tapUID
            )

            let tapFormat = try CoreAudioUtilities.audioFormat(
                objectID: tapID,
                selector: kAudioTapPropertyFormat
            )
            let inputStreams = try CoreAudioUtilities.streamIDs(
                deviceID: aggregateDeviceID,
                scope: kAudioDevicePropertyScopeInput
            )
            let outputStreams = try CoreAudioUtilities.streamIDs(
                deviceID: aggregateDeviceID,
                scope: kAudioDevicePropertyScopeOutput
            )
            guard inputStreams.count == 1, outputStreams.count == 1 else {
                throw AudioEffectError.configuration(
                    "Этот аудиовыход пока не поддерживается: нужен один стереопоток"
                )
            }

            let aggregateInputFormat = try CoreAudioUtilities.audioFormat(
                objectID: inputStreams[0],
                selector: kAudioStreamPropertyVirtualFormat
            )
            let aggregateOutputFormat = try CoreAudioUtilities.audioFormat(
                objectID: outputStreams[0],
                selector: kAudioStreamPropertyVirtualFormat
            )
            let tapLayout = try StereoFloatFormat(tapFormat, name: "системного звука")
            let inputLayout = try StereoFloatFormat(aggregateInputFormat, name: "входа")
            let outputLayout = try StereoFloatFormat(aggregateOutputFormat, name: "выхода")
            guard abs(tapLayout.sampleRate - inputLayout.sampleRate) < 0.001,
                  abs(inputLayout.sampleRate - outputLayout.sampleRate) < 0.001,
                  tapLayout.isInterleaved == inputLayout.isInterleaved else {
                throw AudioEffectError.configuration(
                    "Форматы системного звука и выбранного аудиовыхода не совпадают"
                )
            }

            let newProcessor = NeighborDSP(
                sampleRate: inputLayout.sampleRate,
                inputIsInterleaved: inputLayout.isInterleaved,
                outputIsInterleaved: outputLayout.isInterleaved
            )
            newProcessor.update(parameters)

            var newIOProcID: AudioDeviceIOProcID?
            let ioBlock = makeAudioIOBlock(processor: newProcessor)
            try CoreAudioUtilities.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    aggregateDeviceID,
                    nil,
                    ioBlock
                ),
                operation: "Не удалось создать прямой аудиомаршрут"
            )

            guard let newIOProcID else {
                throw AudioEffectError.configuration("macOS не создала аудиообработчик")
            }

            processor = newProcessor
            ioProcID = newIOProcID

            try CoreAudioUtilities.check(
                AudioDeviceStart(aggregateDeviceID, newIOProcID),
                operation: "Не удалось запустить обработанный звук"
            )

            running = true
            log(parameters)
            logger.notice(
                "Direct tap started at \(inputLayout.sampleRate, privacy: .public) Hz; microphone is excluded"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let hadActiveRoute = running || ioProcID != nil

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        running = false
        ioProcID = nil
        processor = nil
        tapDescription = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if hadActiveRoute {
            logger.notice("Direct tap stopped")
        }
    }

    func apply(_ parameters: EffectParameters) {
        processor?.update(parameters)
        if processor != nil {
            log(parameters)
        }
    }

    nonisolated static func cutoffFrequency(for wall: Double) -> Double {
        let clamped = min(max(wall, 0), 1)
        return 1_400 * pow(450.0 / 1_400.0, clamped)
    }

    private func log(_ parameters: EffectParameters) {
        let cutoff = Self.cutoffFrequency(for: parameters.wall)
        let bassGain = parameters.bass * 12
        let echoMix = parameters.echo * 50
        let roomMix = parameters.room * 60
        let boostGain = parameters.boost * 10
        logger.notice(
            "Applied wall=\(parameters.wall * 100, privacy: .public)% cutoff=\(cutoff, privacy: .public)Hz bass=\(bassGain, privacy: .public)dB echo=\(echoMix, privacy: .public)% room=\(roomMix, privacy: .public)% boost=\(boostGain, privacy: .public)dB"
        )
    }
}

private nonisolated func makeAudioIOBlock(
    processor: NeighborDSP
) -> AudioDeviceIOBlock {
    { [processor] _, inputData, _, outputData, _ in
        processor.render(input: inputData, output: outputData)
    }
}

private final class NeighborDSP: @unchecked Sendable {
    private struct BlockParameters {
        let isCleanPath: Bool
        let wallAlpha: Float
        let wallMix: Float
        let highPassR: Float
        let bassAlpha: Float
        let bassGain: Float
        let echoWet: Float
        let echoFeedback: Float
        let feedbackDampingAlpha: Float
        let roomWet: Float
        let stereoWidth: Float
        let inputTrim: Float
        let outputGain: Float
    }

    private let wall = Atomic<Float>(0)
    private let distance = Atomic<Float>(0)
    private let bass = Atomic<Float>(0)
    private let room = Atomic<Float>(0)
    private let echo = Atomic<Float>(0)
    private let boost = Atomic<Float>(0)
    private let formatMismatch = Atomic<Bool>(false)

    private let sampleRate: Float
    private let inputIsInterleaved: Bool
    private let outputIsInterleaved: Bool
    private var delayLeft: [Float]
    private var delayRight: [Float]
    private var writeIndex = 0

    private let echoLeftFrames: Int
    private let echoRightFrames: Int
    private let earlyLeftOneFrames: Int
    private let earlyLeftTwoFrames: Int
    private let earlyLeftThreeFrames: Int
    private let earlyLeftFourFrames: Int
    private let earlyRightOneFrames: Int
    private let earlyRightTwoFrames: Int
    private let earlyRightThreeFrames: Int
    private let earlyRightFourFrames: Int

    private var previousInputLeft: Float = 0
    private var previousInputRight: Float = 0
    private var highPassLeft: Float = 0
    private var highPassRight: Float = 0
    private var bassLowLeft: Float = 0
    private var bassLowRight: Float = 0
    private var wallOneLeft: Float = 0
    private var wallOneRight: Float = 0
    private var wallTwoLeft: Float = 0
    private var wallTwoRight: Float = 0
    private var wallThreeLeft: Float = 0
    private var wallThreeRight: Float = 0
    private var wallFourLeft: Float = 0
    private var wallFourRight: Float = 0
    private var feedbackDampedLeft: Float = 0
    private var feedbackDampedRight: Float = 0

    init(
        sampleRate: Double,
        inputIsInterleaved: Bool,
        outputIsInterleaved: Bool
    ) {
        self.sampleRate = Float(sampleRate)
        self.inputIsInterleaved = inputIsInterleaved
        self.outputIsInterleaved = outputIsInterleaved
        let delayCapacity = max(4_096, Int(sampleRate * 0.75))
        delayLeft = [Float](repeating: 0, count: delayCapacity)
        delayRight = [Float](repeating: 0, count: delayCapacity)

        func frames(_ milliseconds: Double) -> Int {
            min(delayCapacity - 1, max(1, Int(sampleRate * milliseconds / 1_000)))
        }

        echoLeftFrames = frames(230)
        echoRightFrames = frames(265)
        earlyLeftOneFrames = frames(17)
        earlyLeftTwoFrames = frames(31)
        earlyLeftThreeFrames = frames(47)
        earlyLeftFourFrames = frames(73)
        earlyRightOneFrames = frames(19)
        earlyRightTwoFrames = frames(29)
        earlyRightThreeFrames = frames(53)
        earlyRightFourFrames = frames(71)
    }

    func update(_ parameters: EffectParameters) {
        wall.store(Float(parameters.wall.clamped), ordering: .relaxed)
        distance.store(Float(parameters.distance.clamped), ordering: .relaxed)
        bass.store(Float(parameters.bass.clamped), ordering: .relaxed)
        room.store(Float(parameters.room.clamped), ordering: .relaxed)
        echo.store(Float(parameters.echo.clamped), ordering: .relaxed)
        boost.store(Float(parameters.boost.clamped), ordering: .relaxed)
    }

    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = CoreAudio.UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputs = CoreAudio.UnsafeMutableAudioBufferListPointer(output)

        clear(outputs)

        guard !inputs.isEmpty, !outputs.isEmpty else {
            formatMismatch.store(true, ordering: .relaxed)
            return
        }

        let block = blockParameters()

        if inputIsInterleaved, outputIsInterleaved,
           inputs.count == 1, outputs.count == 1,
           inputs[0].mNumberChannels == 2, outputs[0].mNumberChannels == 2 {
            renderInterleavedToInterleaved(
                input: inputs[0],
                output: outputs[0],
                parameters: block
            )
        } else if !inputIsInterleaved, !outputIsInterleaved,
                  inputs.count == 2, outputs.count == 2,
                  inputs[0].mNumberChannels == 1, inputs[1].mNumberChannels == 1,
                  outputs[0].mNumberChannels == 1, outputs[1].mNumberChannels == 1 {
            renderPlanarToPlanar(
                inputLeft: inputs[0],
                inputRight: inputs[1],
                outputLeft: outputs[0],
                outputRight: outputs[1],
                parameters: block
            )
        } else if inputIsInterleaved, !outputIsInterleaved,
                  inputs.count == 1, outputs.count == 2,
                  inputs[0].mNumberChannels == 2,
                  outputs[0].mNumberChannels == 1, outputs[1].mNumberChannels == 1 {
            renderInterleavedToPlanar(
                input: inputs[0],
                outputLeft: outputs[0],
                outputRight: outputs[1],
                parameters: block
            )
        } else if !inputIsInterleaved, outputIsInterleaved,
                  inputs.count == 2, outputs.count == 1,
                  inputs[0].mNumberChannels == 1, inputs[1].mNumberChannels == 1,
                  outputs[0].mNumberChannels == 2 {
            renderPlanarToInterleaved(
                inputLeft: inputs[0],
                inputRight: inputs[1],
                output: outputs[0],
                parameters: block
            )
        } else {
            formatMismatch.store(true, ordering: .relaxed)
        }
    }

    private func renderInterleavedToInterleaved(
        input: AudioBuffer,
        output: AudioBuffer,
        parameters: BlockParameters
    ) {
        guard let inputData = input.mData, let outputData = output.mData else { return }
        let inputChannels = max(1, Int(input.mNumberChannels))
        let outputChannels = max(1, Int(output.mNumberChannels))
        let inputFrames = Int(input.mDataByteSize) / (MemoryLayout<Float>.size * inputChannels)
        let outputFrames = Int(output.mDataByteSize) / (MemoryLayout<Float>.size * outputChannels)
        let frames = min(inputFrames, outputFrames)
        let source = inputData.assumingMemoryBound(to: Float.self)
        let destination = outputData.assumingMemoryBound(to: Float.self)

        for frame in 0..<frames {
            let inputOffset = frame * inputChannels
            let left = source[inputOffset]
            let right = inputChannels > 1 ? source[inputOffset + 1] : left
            let processed = process(left: left, right: right, parameters: parameters)
            let outputOffset = frame * outputChannels
            destination[outputOffset] = outputChannels == 1 ? (processed.0 + processed.1) * 0.5 : processed.0
            if outputChannels > 1 {
                destination[outputOffset + 1] = processed.1
            }
        }
    }

    private func renderPlanarToPlanar(
        inputLeft: AudioBuffer,
        inputRight: AudioBuffer,
        outputLeft: AudioBuffer,
        outputRight: AudioBuffer,
        parameters: BlockParameters
    ) {
        guard let inputLeftData = inputLeft.mData,
              let inputRightData = inputRight.mData,
              let outputLeftData = outputLeft.mData,
              let outputRightData = outputRight.mData else { return }

        let inputLeftFrames = Int(inputLeft.mDataByteSize) / MemoryLayout<Float>.size
        let inputRightFrames = Int(inputRight.mDataByteSize) / MemoryLayout<Float>.size
        let outputLeftFrames = Int(outputLeft.mDataByteSize) / MemoryLayout<Float>.size
        let outputRightFrames = Int(outputRight.mDataByteSize) / MemoryLayout<Float>.size
        let frames = min(
            min(inputLeftFrames, inputRightFrames),
            min(outputLeftFrames, outputRightFrames)
        )
        let sourceLeft = inputLeftData.assumingMemoryBound(to: Float.self)
        let sourceRight = inputRightData.assumingMemoryBound(to: Float.self)
        let destinationLeft = outputLeftData.assumingMemoryBound(to: Float.self)
        let destinationRight = outputRightData.assumingMemoryBound(to: Float.self)

        for frame in 0..<frames {
            let processed = process(
                left: sourceLeft[frame],
                right: sourceRight[frame],
                parameters: parameters
            )
            destinationLeft[frame] = processed.0
            destinationRight[frame] = processed.1
        }
    }

    private func renderInterleavedToPlanar(
        input: AudioBuffer,
        outputLeft: AudioBuffer,
        outputRight: AudioBuffer,
        parameters: BlockParameters
    ) {
        guard let inputData = input.mData,
              let outputLeftData = outputLeft.mData,
              let outputRightData = outputRight.mData else { return }
        let inputChannels = max(1, Int(input.mNumberChannels))
        let frames = min(
            Int(input.mDataByteSize) / (MemoryLayout<Float>.size * inputChannels),
            min(
                Int(outputLeft.mDataByteSize) / MemoryLayout<Float>.size,
                Int(outputRight.mDataByteSize) / MemoryLayout<Float>.size
            )
        )
        let source = inputData.assumingMemoryBound(to: Float.self)
        let destinationLeft = outputLeftData.assumingMemoryBound(to: Float.self)
        let destinationRight = outputRightData.assumingMemoryBound(to: Float.self)

        for frame in 0..<frames {
            let inputOffset = frame * inputChannels
            let left = source[inputOffset]
            let right = inputChannels > 1 ? source[inputOffset + 1] : left
            let processed = process(left: left, right: right, parameters: parameters)
            destinationLeft[frame] = processed.0
            destinationRight[frame] = processed.1
        }
    }

    private func renderPlanarToInterleaved(
        inputLeft: AudioBuffer,
        inputRight: AudioBuffer,
        output: AudioBuffer,
        parameters: BlockParameters
    ) {
        guard let inputLeftData = inputLeft.mData,
              let inputRightData = inputRight.mData,
              let outputData = output.mData else { return }
        let outputChannels = max(1, Int(output.mNumberChannels))
        let frames = min(
            min(
                Int(inputLeft.mDataByteSize) / MemoryLayout<Float>.size,
                Int(inputRight.mDataByteSize) / MemoryLayout<Float>.size
            ),
            Int(output.mDataByteSize) / (MemoryLayout<Float>.size * outputChannels)
        )
        let sourceLeft = inputLeftData.assumingMemoryBound(to: Float.self)
        let sourceRight = inputRightData.assumingMemoryBound(to: Float.self)
        let destination = outputData.assumingMemoryBound(to: Float.self)

        for frame in 0..<frames {
            let processed = process(
                left: sourceLeft[frame],
                right: sourceRight[frame],
                parameters: parameters
            )
            let outputOffset = frame * outputChannels
            destination[outputOffset] = outputChannels == 1 ? (processed.0 + processed.1) * 0.5 : processed.0
            if outputChannels > 1 {
                destination[outputOffset + 1] = processed.1
            }
        }
    }

    private func process(
        left inputLeft: Float,
        right inputRight: Float,
        parameters: BlockParameters
    ) -> (Float, Float) {
        let mid = (inputLeft + inputRight) * 0.5
        let side = (inputLeft - inputRight) * 0.5 * parameters.stereoWidth
        let narrowedLeft = (mid + side) * parameters.inputTrim
        let narrowedRight = (mid - side) * parameters.inputTrim

        highPassLeft = narrowedLeft - previousInputLeft + parameters.highPassR * highPassLeft
        highPassRight = narrowedRight - previousInputRight + parameters.highPassR * highPassRight
        previousInputLeft = narrowedLeft
        previousInputRight = narrowedRight

        bassLowLeft += parameters.bassAlpha * (highPassLeft - bassLowLeft)
        bassLowRight += parameters.bassAlpha * (highPassRight - bassLowRight)
        let bassShapedLeft = highPassLeft + (parameters.bassGain - 1) * bassLowLeft
        let bassShapedRight = highPassRight + (parameters.bassGain - 1) * bassLowRight

        wallOneLeft += parameters.wallAlpha * (bassShapedLeft - wallOneLeft)
        wallOneRight += parameters.wallAlpha * (bassShapedRight - wallOneRight)
        wallTwoLeft += parameters.wallAlpha * (wallOneLeft - wallTwoLeft)
        wallTwoRight += parameters.wallAlpha * (wallOneRight - wallTwoRight)
        wallThreeLeft += parameters.wallAlpha * (wallTwoLeft - wallThreeLeft)
        wallThreeRight += parameters.wallAlpha * (wallTwoRight - wallThreeRight)
        wallFourLeft += parameters.wallAlpha * (wallThreeLeft - wallFourLeft)
        wallFourRight += parameters.wallAlpha * (wallThreeRight - wallFourRight)

        let shapedLeft = bassShapedLeft
            + (wallFourLeft - bassShapedLeft) * parameters.wallMix
        let shapedRight = bassShapedRight
            + (wallFourRight - bassShapedRight) * parameters.wallMix
        let echoLeft = delayLeft[wrappedIndex(writeIndex - echoLeftFrames)]
        let echoRight = delayRight[wrappedIndex(writeIndex - echoRightFrames)]

        let feedbackLeft = echoLeft * 0.85 + echoRight * 0.15
        let feedbackRight = echoRight * 0.85 + echoLeft * 0.15
        feedbackDampedLeft += parameters.feedbackDampingAlpha
            * (feedbackLeft - feedbackDampedLeft)
        feedbackDampedRight += parameters.feedbackDampingAlpha
            * (feedbackRight - feedbackDampedRight)

        delayLeft[writeIndex] = limited(
            shapedLeft + feedbackDampedLeft * parameters.echoFeedback,
            limit: 2
        )
        delayRight[writeIndex] = limited(
            shapedRight + feedbackDampedRight * parameters.echoFeedback,
            limit: 2
        )

        let reflectionLeft =
            delayLeft[wrappedIndex(writeIndex - earlyLeftOneFrames)] * 0.28
            + delayLeft[wrappedIndex(writeIndex - earlyLeftTwoFrames)] * 0.20
            + delayLeft[wrappedIndex(writeIndex - earlyLeftThreeFrames)] * 0.14
            + delayLeft[wrappedIndex(writeIndex - earlyLeftFourFrames)] * 0.10
        let reflectionRight =
            delayRight[wrappedIndex(writeIndex - earlyRightOneFrames)] * 0.28
            + delayRight[wrappedIndex(writeIndex - earlyRightTwoFrames)] * 0.20
            + delayRight[wrappedIndex(writeIndex - earlyRightThreeFrames)] * 0.14
            + delayRight[wrappedIndex(writeIndex - earlyRightFourFrames)] * 0.10

        let wetLeft = shapedLeft
            + reflectionLeft * parameters.roomWet
            + echoLeft * parameters.echoWet
        let wetRight = shapedRight
            + reflectionRight * parameters.roomWet
            + echoRight * parameters.echoWet

        writeIndex += 1
        if writeIndex == delayLeft.count {
            writeIndex = 0
        }

        if parameters.isCleanPath {
            if parameters.outputGain == 1 {
                return (inputLeft, inputRight)
            }

            return (
                softLimited(inputLeft * parameters.outputGain),
                softLimited(inputRight * parameters.outputGain)
            )
        }

        return (
            softLimited(wetLeft * parameters.outputGain),
            softLimited(wetRight * parameters.outputGain)
        )
    }

    private func blockParameters() -> BlockParameters {
        let wall = self.wall.load(ordering: .relaxed)
        let distance = self.distance.load(ordering: .relaxed)
        let bass = self.bass.load(ordering: .relaxed)
        let room = self.room.load(ordering: .relaxed)
        let echo = self.echo.load(ordering: .relaxed)
        let boost = self.boost.load(ordering: .relaxed)

        let cutoff = Float(AudioEffectController.cutoffFrequency(for: Double(wall)))
        let wallAlpha = 1 - exp(-2 * Float.pi * cutoff / sampleRate)
        let highPassR = exp(-2 * Float.pi * 30 / sampleRate)
        let bassAlpha = 1 - exp(-2 * Float.pi * 170 / sampleRate)
        let bassGain = pow(10, bass * 12 / 20)
        let feedbackDampingAlpha = 1 - exp(-2 * Float.pi * 750 / sampleRate)
        let distanceGain = pow(10, -(distance * 10) / 20)
        let headroomDecibels = bass * 10 + room * 3 + echo * 4
        let effectHeadroom = pow(10, -headroomDecibels / 20)

        return BlockParameters(
            isCleanPath: wall == 0
                && distance == 0
                && bass == 0
                && room == 0
                && echo == 0,
            wallAlpha: wallAlpha,
            wallMix: wall,
            highPassR: highPassR,
            bassAlpha: bassAlpha,
            bassGain: bassGain,
            echoWet: echo * 0.5,
            echoFeedback: min(0.52, echo * 0.52),
            feedbackDampingAlpha: feedbackDampingAlpha,
            roomWet: room * 0.6,
            stereoWidth: max(0.18, 1 - distance * 0.82),
            inputTrim: distanceGain * effectHeadroom,
            outputGain: pow(10, boost * 10 / 20)
        )
    }

    private func wrappedIndex(_ value: Int) -> Int {
        value >= 0 ? value : value + delayLeft.count
    }

    private func clear(_ buffers: CoreAudio.UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private func limited(_ value: Float, limit: Float) -> Float {
        min(max(value, -limit), limit)
    }

    private func softLimited(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > 0.9 else { return value }
        let compressed = 0.9 + 0.1 * tanh((magnitude - 0.9) / 0.1)
        return value < 0 ? -compressed : compressed
    }
}

private struct StereoFloatFormat {
    let sampleRate: Double
    let isInterleaved: Bool

    init(_ format: AudioStreamBasicDescription, name: String) throws {
        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let isPlanar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let expectedBytesPerFrame: UInt32 = isPlanar ? 4 : 8

        guard format.mFormatID == kAudioFormatLinearPCM,
              (format.mFormatFlags & requiredFlags) == requiredFlags,
              (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0,
              format.mSampleRate.isFinite,
              format.mSampleRate > 0,
              format.mChannelsPerFrame == 2,
              format.mBitsPerChannel == 32,
              format.mFramesPerPacket == 1,
              format.mBytesPerFrame == expectedBytesPerFrame,
              format.mBytesPerPacket == expectedBytesPerFrame else {
            throw AudioEffectError.configuration("Неподдерживаемый формат \(name)")
        }

        sampleRate = format.mSampleRate
        isInterleaved = !isPlanar
    }
}

private extension Double {
    var clamped: Double {
        min(max(self, 0), 1)
    }
}

private enum AudioEffectError: LocalizedError {
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case let .configuration(message): message
        }
    }
}

import CoreAudio
import Darwin
import RTAtomic

/// POD memory owned by TapSession. Core Audio is the sole writer of the ramp history.
struct RenderState {
    let atomic: OpaquePointer
    let tapBufferCount: Int
    let channelsPerBuffer: Int
    var previousGain: Float = 1
}

let renderAudio: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    guard let context else { return noErr }
    let state = context.assumingMemoryBound(to: RenderState.self)
    let atomic = state.pointee.atomic
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    let buffers = state.pointee.tapBufferCount
    let channels = state.pointee.channelsPerBuffer

    guard outputs.count == buffers, inputs.count == buffers else {
        clearAudio(outputs)
        mixer_render_fail(atomic)
        return noErr
    }

    let isPlaying = mixer_playback_enabled(atomic) != 0
    let needsSignal = !isPlaying && mixer_signal_present(atomic) == 0
    let target = mixer_gain_load(atomic)
    let previous = state.pointee.previousGain
    let bytesPerFrame = channels * MemoryLayout<Float>.stride
    var frameCount: Int?
    var hadSignal = false

    for index in 0..<buffers {
        let source = inputs[index]
        let destination = outputs[index]
        guard source.mNumberChannels == channels, destination.mNumberChannels == channels,
              source.mDataByteSize == destination.mDataByteSize,
              source.mDataByteSize.isMultiple(of: UInt32(bytesPerFrame)) else {
            clearAudio(outputs)
            mixer_render_fail(atomic)
            return noErr
        }
        let frames = Int(source.mDataByteSize) / bytesPerFrame
        if let frameCount, frames != frameCount {
            clearAudio(outputs)
            mixer_render_fail(atomic)
            return noErr
        }
        frameCount = frames
        if frames == 0 { continue }
        guard let sourceData = source.mData, let destinationData = destination.mData else {
            clearAudio(outputs)
            mixer_render_fail(atomic)
            return noErr
        }

        let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
        if isPlaying {
            let destinationSamples = destinationData.assumingMemoryBound(to: Float.self)
            let ramp = GainRamp(from: previous, to: target, frames: frames)
            for frame in 0..<frames {
                let gain = ramp.value(after: frame + 1)
                let offset = frame * channels
                for channel in 0..<channels {
                    destinationSamples[offset + channel] = sourceSamples[offset + channel] * gain
                }
            }
        } else {
            if needsSignal && !hadSignal {
                for sample in 0..<(frames * channels) {
                    let value = sourceSamples[sample]
                    if value.isFinite && value != 0 {
                        hadSignal = true
                        break
                    }
                }
            }
            memset(destinationData, 0, Int(destination.mDataByteSize))
        }
    }

    if let frameCount, frameCount > 0 {
        if isPlaying { state.pointee.previousGain = target }
        if hadSignal { mixer_signal_mark(atomic) }
        mixer_callback_mark(atomic)
    }
    return noErr
}

@inline(__always)
private func clearAudio(_ outputs: UnsafeMutableAudioBufferListPointer) {
    for buffer in outputs {
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}

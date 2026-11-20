import CoreAudio
import RTAtomic
import Testing
@testable import AudioCore

@Test func preflightDetectsSignalAndLeavesPlaybackToOriginalApp() throws {
    let atomic = try #require(mixer_atomics_create(0))
    defer { mixer_atomics_destroy(atomic) }
    var state = RenderState(atomic: atomic, tapBufferCount: 1, channelsPerBuffer: 2)
    let output = runRender(samples: [1, -1, 1, -1], state: &state)
    #expect(output == [0, 0, 0, 0])
    #expect(mixer_signal_present(atomic) == 1)
    #expect(mixer_callback_count(atomic) == 1)
    #expect(state.previousGain == 1)
}

@Test func callbackAttenuatesBothChannelsAndFailsSafelyOnMismatchedBuffers() throws {
    let atomic = try #require(mixer_atomics_create(0))
    defer { mixer_atomics_destroy(atomic) }
    mixer_playback_enable(atomic)
    var state = RenderState(atomic: atomic, tapBufferCount: 1, channelsPerBuffer: 2)
    let output = runRender(samples: [1, -1, 1, -1], state: &state)
    #expect(output == [0.5, -0.5, 0, 0])
    #expect(state.previousGain == 0)
    mixer_gain_store(atomic, 1)
    #expect(runRender(samples: [1, -1, 1, -1], state: &state) == [0.5, -0.5, 1, -1])
    #expect(runRender(samples: [1, -1, 1, -1], state: &state, dropOutputSamples: 2) == [0, 0])
    #expect(mixer_render_failed(atomic) == 1)
}

private func runRender(
    samples: [Float], state: inout RenderState, dropOutputSamples: Int = 0
) -> [Float] {
    var samples = samples
    var output = Array(repeating: Float(99), count: samples.count - dropOutputSamples)
    samples.withUnsafeMutableBytes { inputData in
        output.withUnsafeMutableBytes { outputData in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers:
                AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inputData.count), mData: inputData.baseAddress)
            )
            var result = AudioBufferList(mNumberBuffers: 1, mBuffers:
                AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outputData.count), mData: outputData.baseAddress)
            )
            var time = AudioTimeStamp()
            withUnsafePointer(to: &time) { timestamp in
                withUnsafeMutablePointer(to: &state) { context in
                    _ = renderAudio(0, timestamp, &input, timestamp, &result, timestamp, context)
                }
            }
        }
    }
    return output
}

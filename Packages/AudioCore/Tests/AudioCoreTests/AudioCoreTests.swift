import CoreAudio
import Testing
@testable import AudioCore

@Test func gainClampsAndInvalidValuesFailOpen() {
    #expect(Gain(-1).value == 0)
    #expect(Gain(2) == .unity)
    #expect(Gain(.nan) == .unity)
    #expect(Gain(.infinity) == .unity)
    #expect(Gain(0.5).value == 0.5)
}

@Test func gainRampsBothDirectionsOverFrames() {
    let mute = GainRamp(from: 1, to: 0, frames: 4)
    let unmute = GainRamp(from: 0, to: 1, frames: 4)
    #expect(mute.value(after: 1) == 0.75)
    #expect(mute.value(after: 4) == 0)
    #expect(unmute.value(after: 1) == 0.25)
    #expect(unmute.value(after: 4) == 1)
    #expect(GainRamp(from: 0.5, to: 1, frames: 0).value(after: 0) == 0.5)
}

@Test func refusesToRerouteAppsWithDifferentOrUnknownDevices() {
    #expect(commonOutputDevice(in: [[9], [9]]) == 9)
    #expect(commonOutputDevice(in: [[9], [10]]) == nil)
    #expect(commonOutputDevice(in: [[9, 10]]) == nil)
    #expect(commonOutputDevice(in: [[9], []]) == nil)
    #expect(commonOutputDevice(in: [[0]]) == nil)
    #expect(commonOutputDevice(in: []) == nil)
}

@Test func acceptsBoundedNativeFloatAudioOnly() {
    var format = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    #expect(PCMLayout(format)?.bufferChannels == [2])
    format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
    format.mBytesPerFrame = 4
    #expect(PCMLayout(format)?.bufferChannels == [1, 1])
    format.mBytesPerFrame = 8
    #expect(PCMLayout(format) == nil)
    format.mBytesPerFrame = 4
    format.mFormatFlags |= kAudioFormatFlagIsBigEndian
    #expect(PCMLayout(format) == nil)
}

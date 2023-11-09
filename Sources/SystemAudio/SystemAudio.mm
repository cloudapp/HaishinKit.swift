//
//  SystemAudio.mm
//  CloudApp
//
//  Created by Gordon Childs on 10/29/2023.
//

#import "SystemAudio.h"
#include "SystemAudioMixer.hpp"
#include <memory> // std::unique_ptr
#include <os/log.h>
#include <string.h> // memset, memcmp

#include "SystemAudioUtilities.hpp"

class SystemAudio
{
  public:
    SystemAudio();

    CMSampleBufferRef processSampleBuffer(CMSampleBufferRef sampleBuffer);

  private:
    AudioStreamBasicDescription sampleBufferASBD_;
    std::unique_ptr<SystemAudioMixer> mixer_;

    auto_CMFormatDescription outputSampleBufferFormatDesc_;

    unique_AudioBufferList_ptr inputABL_;
    UInt32 inputABLSize_;

    unique_AudioBufferList_ptr outputABL_;
    UInt32 outputABLBufferBytesPerSample_;
    UInt32 outputABLTotalBufferBytesPerSample_;

    bool createSystemAudioMixer(const AudioStreamBasicDescription &newInputASBD);
};

SystemAudio::SystemAudio()
{
    memset(&sampleBufferASBD_, 0, sizeof(sampleBufferASBD_));
}

CMSampleBufferRef SystemAudio::processSampleBuffer(CMSampleBufferRef sampleBuffer)
{
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format)
        return nullptr;

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (!asbd)
        return nullptr;

    if (memcmp(asbd, &sampleBufferASBD_, sizeof(sampleBufferASBD_)) != 0)
    {
        os_log(OS_LOG_DEFAULT, "sample format changed");
        if (!createSystemAudioMixer(*asbd))
            return nullptr;
        
        sampleBufferASBD_ = *asbd;
    }

    OSStatus status;

    auto_CMBlockBuffer autoInputBlockBuffer;
    {
        CMBlockBufferRef blockBuffer;
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, nullptr, inputABL_.get(), inputABLSize_, kCFAllocatorDefault, kCFAllocatorDefault,
            0 /* flags */, &blockBuffer);
        if (noErr != status)
            return nullptr;

        autoInputBlockBuffer.reset(blockBuffer);
    }

    CMSampleTimingInfo timingInfo;
    status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
    if (noErr != status)
        return nullptr;

    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);

    const size_t kOutputBlockSize = numSamples * outputABLTotalBufferBytesPerSample_;

    auto outputBuffer = std::unique_ptr<uint8_t[]>(new uint8_t[kOutputBlockSize]);

    // setup pointers and sizes in output ABL
    uint8_t *dst = outputBuffer.get();
    const UInt32 kPerChannelByteSize = outputABLBufferBytesPerSample_ * static_cast<UInt32>(numSamples);

    for (UInt32 i = 0; i < outputABL_->mNumberBuffers; i++)
    {
        AudioBuffer &ab = outputABL_->mBuffers[i];
        ab.mData = dst;
        ab.mDataByteSize = kPerChannelByteSize;
        dst += kPerChannelByteSize;
    }

    // mix down input and store it in output buffer
    status = mixer_->mix(static_cast<UInt32>(numSamples), inputABL_.get(), outputABL_.get());
    if (noErr != status)
        return nullptr;

    // create a CMSampleBufferRef from the mixed down 2 channel sample data
    auto_CMBlockBuffer outputBlockBuffer;
    {
        CMBlockBufferRef blockBuffer;
        status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, kOutputBlockSize, kCFAllocatorDefault,
                                                    nullptr, 0, kOutputBlockSize, kCMBlockBufferAssureMemoryNowFlag,
                                                    &blockBuffer);
        if (noErr != status)
            return nullptr;

        outputBlockBuffer.reset(blockBuffer);
    }

    status = CMBlockBufferReplaceDataBytes(outputBuffer.get(), outputBlockBuffer.get(), 0, kOutputBlockSize);
    if (noErr != status)
        return nullptr;

    auto_CMSampleBuffer outputSampleBuffer;
    {
        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreate(kCFAllocatorDefault, outputBlockBuffer.get(), true, nullptr, nullptr,
                                      outputSampleBufferFormatDesc_.get(), numSamples, 1, &timingInfo, 0, nullptr,
                                      &sampleBuffer);
        if (noErr != status)
            return nullptr;

        outputSampleBuffer.reset(sampleBuffer);
    }

    return outputSampleBuffer.release();
}

bool SystemAudio::createSystemAudioMixer(const AudioStreamBasicDescription &inputASBD)
{
    OSStatus status;

    if (mixer_)
    {
        status = mixer_->uninitialize();
        if (noErr != status)
            os_log(OS_LOG_DEFAULT, "failed to uninit mixer: %x", status);

        memset(&sampleBufferASBD_, 0, sizeof(sampleBufferASBD_));
    }

    outputSampleBufferFormatDesc_.reset(nullptr);

    const bool isInterleaved = !(inputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved);

    // stereo output
    const UInt32 kOutputNumChannels = 2;
    AudioStreamBasicDescription outputASBD = inputASBD;
    outputASBD.mChannelsPerFrame = kOutputNumChannels;

    // let input and output interleaved-ness match, but if it is interleaved,
    // fix up the packet and frame sizes. mostly non-interleaved however.
    if (isInterleaved)
    {
        outputASBD.mBytesPerPacket = kOutputNumChannels * outputASBD.mBitsPerChannel / 8;
        outputASBD.mBytesPerFrame = kOutputNumChannels * outputASBD.mBitsPerChannel / 8;
    }

    {
        CMFormatDescriptionRef formatDesc;

        status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &outputASBD, 0, nullptr, 0, nullptr, nullptr,
                                                &formatDesc);
        if (noErr != status)
            return false;

        outputSampleBufferFormatDesc_.reset(formatDesc);
    }

    std::unique_ptr<SystemAudioMixer> newMixer(new SystemAudioMixer);

    status = newMixer->initialize(inputASBD, outputASBD);
    if (noErr != status)
    {
        os_log(OS_LOG_DEFAULT, "failed to initialize mixer: %x", status);
        return false;
    }

    mixer_ = std::move(newMixer);

    {
        const UInt32 numAudioBuffers = isInterleaved ? 1 : inputASBD.mChannelsPerFrame;

        UInt32 ablSize = sizeof(AudioBufferList) + (numAudioBuffers - 1) * sizeof(AudioBuffer);
        inputABL_.reset(reinterpret_cast<AudioBufferList *>(malloc(ablSize)));
        inputABLSize_ = ablSize;

        inputABL_->mNumberBuffers = numAudioBuffers;
    }
    {
        const UInt32 numAudioBuffers = isInterleaved ? 1 : outputASBD.mChannelsPerFrame;

        UInt32 ablSize = sizeof(AudioBufferList) + (numAudioBuffers - 1) * sizeof(AudioBuffer);
        outputABL_.reset(reinterpret_cast<AudioBufferList *>(malloc(ablSize)));

        // init non-pointer and channel size fields of output ABL
        outputABL_->mNumberBuffers = numAudioBuffers;

        UInt32 outputChannelsPerBuffer = outputASBD.mChannelsPerFrame / numAudioBuffers;

        for (UInt32 i = 0; i < numAudioBuffers; i++)
        {
            outputABL_->mBuffers[i].mNumberChannels = outputChannelsPerBuffer;
        }

        outputABLBufferBytesPerSample_ = outputASBD.mBytesPerFrame;
        outputABLTotalBufferBytesPerSample_ = numAudioBuffers * outputASBD.mBytesPerFrame;
    }
    return true;
}

static SystemAudio gSystemAudioBufferProcesser;

CMSampleBufferRef SystemAudioProcessSampleBuffer(CMSampleBufferRef sampleBuffer)
{
    return gSystemAudioBufferProcesser.processSampleBuffer(sampleBuffer);
}

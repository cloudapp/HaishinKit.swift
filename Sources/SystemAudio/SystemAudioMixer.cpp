//
//  SystemAudioMixer.cpp
//  CloudApp
//
//  Created by Gordon Childs on 10/29/23.
//

#include "SystemAudioMixer.hpp"

SystemAudioMixer::SystemAudioMixer() : sampleTime_(0)
{
}

OSStatus SystemAudioMixer::configureMixer()
{
    OSStatus status;
    // Using one input and output bus, channel (2+n)x2 matrix
    UInt32 inputBusses = 1;
    status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_BusCount, kAudioUnitScope_Input, 0, &inputBusses,
                                  sizeof(inputBusses));
    if (noErr != status)
        return status;

    UInt32 outputBusses = 1;
    status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_BusCount, kAudioUnitScope_Output, 0, &outputBusses,
                                  sizeof(outputBusses));
    if (noErr != status)
        return status;

    return noErr;
}

OSStatus SystemAudioMixer::configureStreamFormats(const AudioStreamBasicDescription &inputASBD,
                                                  const AudioStreamBasicDescription &outputASBD)
{
    // duplicate hardware stream formats to app facing stream formats
    OSStatus status;
    UInt32 size;

    // input
    {
        size = sizeof(inputASBD);

        // set mixer input format
        status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inputASBD,
                                      sizeof(inputASBD));
        if (noErr != status)
            return status;

        mixerInputChannels_ = inputASBD.mChannelsPerFrame;
    }

    // output
    {
        // set mixer output format
        size = sizeof(outputASBD);
        status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                      &outputASBD, sizeof(outputASBD));
        if (noErr != status)
            return status;

        mixerOutputChannels_ = outputASBD.mChannelsPerFrame;
    }

    return noErr;
}

OSStatus SystemAudioMixer::renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                          const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                                          AudioBufferList *ioData)
{
    SystemAudioMixer *pThis = reinterpret_cast<SystemAudioMixer *>(inRefCon);

    // copy only the input buffer pointers, thanks to kAudioUnitProperty_ShouldAllocateBuffer
    const AudioBufferList *inABL = pThis->renderCallbackInputABL_;

    if (inABL->mNumberBuffers != ioData->mNumberBuffers)
        return kAudio_ParamError;

    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
    {
        const AudioBuffer &inBuffer = inABL->mBuffers[i];
        AudioBuffer &outBuffer = ioData->mBuffers[i];

        if (!(inBuffer.mNumberChannels == outBuffer.mNumberChannels &&
              inBuffer.mDataByteSize == outBuffer.mDataByteSize))
        {
            return kAudio_ParamError;
        }

        outBuffer.mData = inBuffer.mData;
    }

    return noErr;
}

OSStatus SystemAudioMixer::initialize(const AudioStreamBasicDescription &inputASBD,
                                      const AudioStreamBasicDescription &outputASBD)
{
    AudioComponentDescription mixerDesc = {0};
    mixerDesc.componentType = kAudioUnitType_Mixer;
    mixerDesc.componentSubType = kAudioUnitSubType_MatrixMixer;
    mixerDesc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent mixerComp = AudioComponentFindNext(nullptr, &mixerDesc);
    if (!mixerComp)
        return kAudioUnitErr_ExtensionNotFound;

    OSStatus status;

    status = AudioComponentInstanceNew(mixerComp, &mixerUnit_);
    if (noErr != status)
        return status;

    status = configureMixer();
    if (noErr != status)
        return status;

    status = configureStreamFormats(inputASBD, outputASBD);
    if (noErr != status)
        return status;

    // pass input ABL data to AudioUnitRender without copying
    UInt32 shouldAllocateBuffer = 0;
    status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Input, 0,
                                  &shouldAllocateBuffer, sizeof(shouldAllocateBuffer));
    if (noErr != status)
        return status;

    AURenderCallbackStruct callbackStruct = {
        .inputProc = renderCallback,
        .inputProcRefCon = this,
    };

    status = AudioUnitSetProperty(mixerUnit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0,
                                  &callbackStruct, sizeof(callbackStruct));
    if (noErr != status)
        return status;

    status = AudioUnitInitialize(mixerUnit_);
    if (noErr != status)
        return status;

    // set global mixer volume to 1.0
    status = AudioUnitSetParameter(mixerUnit_, kMatrixMixerParam_Volume, kAudioUnitScope_Global, 0xFFFFFFFF, 1.0, 0);
    if (noErr != status)
        return status;

    // set all input and output volumes to 1
    for (UInt32 i = 0; i < mixerInputChannels_; i++)
    {
        status = AudioUnitSetParameter(mixerUnit_, kMatrixMixerParam_Volume, kAudioUnitScope_Input, i, 1.0, 0);
        if (noErr != status)
            return status;
    }

    for (UInt32 i = 0; i < mixerOutputChannels_; i++)
    {
        status = AudioUnitSetParameter(mixerUnit_, kMatrixMixerParam_Volume, kAudioUnitScope_Output, i, 1.0, 0);
        if (noErr != status)
            return status;
    }

    return noErr;
}

OSStatus SystemAudioMixer::uninitialize()
{
    OSStatus status;

    status = AudioUnitUninitialize(mixerUnit_);
    if (noErr != status)
        return status;

    status = AudioComponentInstanceDispose(mixerUnit_);
    if (noErr != status)
        return status;

    return noErr;
}

OSStatus SystemAudioMixer::setCrossoverVolume(int inputChannelIndex, int outputChannelIndex, float volume)
{
    OSStatus status;

    status = AudioUnitSetParameter(mixerUnit_, kMatrixMixerParam_Volume, kAudioUnitScope_Global,
                                   (inputChannelIndex << 16) | outputChannelIndex, volume, 0);
    if (noErr != status)
        return status;

    return noErr;
}

OSStatus SystemAudioMixer::mix(UInt32 inNumberFrames, AudioBufferList *inputABL, AudioBufferList *outputABL)
{
    AudioTimeStamp ts = {0};
    ts.mSampleTime = sampleTime_;
    ts.mFlags = kAudioTimeStampSampleTimeValid;

    renderCallbackInputABL_ = inputABL;

    OSStatus status;
    status = AudioUnitRender(mixerUnit_, nullptr, &ts, 0 /*bus 0*/, inNumberFrames, outputABL);

    if (noErr == status)
    {
        sampleTime_ += inNumberFrames;
    }

    return status;
}

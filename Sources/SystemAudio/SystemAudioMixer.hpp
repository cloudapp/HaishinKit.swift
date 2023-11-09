//
//  SystemAudioMixer.hpp
//  CloudApp
//
//  Created by Gordon Childs on 10/29/23.
//

#ifndef SystemAudioMixer_hpp
#define SystemAudioMixer_hpp

#include <AudioToolbox/AudioToolbox.h>

class SystemAudioMixer
{
  public:
    SystemAudioMixer();

    OSStatus initialize(const AudioStreamBasicDescription &inputASBD, const AudioStreamBasicDescription &outputASBD);
    OSStatus uninitialize();

    OSStatus setCrossoverVolume(int inputChannelIndex, int outputChannelIndex, float volume);

    OSStatus mix(UInt32 inNumberFrames, AudioBufferList *inputABL, AudioBufferList *outputABL);

  private:
    AudioUnit mixerUnit_;

    UInt32 mixerInputChannels_;
    UInt32 mixerOutputChannels_;

    Float64 sampleTime_;

    AudioBufferList *renderCallbackInputABL_;

    OSStatus configureStreamFormats(const AudioStreamBasicDescription &inputASBD,
                                    const AudioStreamBasicDescription &outputASBD);
    OSStatus configureMixer();

    static OSStatus renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                   const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                                   AudioBufferList *ioData);
};

#endif /* SystemAudioMixer_hpp */

//
//  SystemAudio.h
//  CloudApp
//
//  Created by Gordon Childs on 10/29/2023.
//

#ifndef SystemAudio_h
#define SystemAudio_h

#import <CoreMedia/CoreMedia.h>   // CMSampleBufferRef

#ifdef __cplusplus
extern "C"
{
#endif

    CMSampleBufferRef SystemAudioProcessSampleBuffer(CMSampleBufferRef sampleBuffer);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* SystemAudio_h */

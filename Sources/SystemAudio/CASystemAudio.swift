//
//  CASystemAudio.swift
//  HaishinKit macOS
//
//  Created by Gordon Childs on 11/15/2023.
//  Copyright © 2023 Shogo Endo. All rights reserved.
//

import AVFoundation
import SystemAudio

public class CASystemAudio {
    public static func processAudioSampleBuffer(sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        return SystemAudioProcessSampleBuffer(sampleBuffer)?.takeRetainedValue()
    }

    public static func startCapture(captureDevice: AVCaptureDevice?) {
        
    }

    public static func stopCapture() {
        
    }
}


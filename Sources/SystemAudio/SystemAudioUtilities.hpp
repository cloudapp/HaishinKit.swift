//
//  SystemAudioUtilities.hpp
//  CloudApp
//
//  Created by Gordon Childs on 11/8/2023.
//

#ifndef SystemAudioUtilities_h
#define SystemAudioUtilities_h

// https://stackoverflow.com/a/3477578/22147
struct free_delete
{
    void operator()(void *x)
    {
        free(x);
    }
};

using unique_AudioBufferList_ptr = std::unique_ptr<AudioBufferList, free_delete>;

template <typename T> class AutoCFType
{
  public:
    ~AutoCFType()
    {
        if (type_)
            CFRelease(type_);
    }
    void reset(T type)
    {
        if (type_)
            CFRelease(type_);
        type_ = type;
    }
    T release()
    {
        T result = (T)(type_);
        type_ = nullptr;
        return result;
    }

    T get()
    {
        return (T)(type_);
    }

  private:
    CFTypeRef type_ = nullptr;
};

using auto_CMSampleBuffer = AutoCFType<CMSampleBufferRef>;
using auto_CMBlockBuffer = AutoCFType<CMBlockBufferRef>;
using auto_CMFormatDescription = AutoCFType<CMFormatDescriptionRef>;

#endif /* SystemAudioUtilities_h */

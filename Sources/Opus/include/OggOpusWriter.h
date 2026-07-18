#import <Foundation/Foundation.h>
#import <opus/opus_defines.h>

NS_ASSUME_NONNULL_BEGIN

@class DataItem;

typedef NS_ENUM(NSInteger, OggOpusWriterApplication) {
  OggOpusWriterApplicationVoip = OPUS_APPLICATION_VOIP,
  OggOpusWriterApplicationAudio = OPUS_APPLICATION_AUDIO,
};

@interface OggOpusWriter : NSObject

- (instancetype)initWithInputSampleRate:(NSInteger)inputSampleRate
                                bitrate:(NSInteger)bitrate;

- (instancetype)initWithInputSampleRate:(NSInteger)inputSampleRate
                                bitrate:(NSInteger)bitrate
                            application:(OggOpusWriterApplication)application
    NS_DESIGNATED_INITIALIZER;

- (bool)beginWithDataItem:(DataItem *)dataItem;
- (bool)beginAppendWithDataItem:(DataItem *)dataItem;

- (bool)writeFrame:(uint8_t *_Nullable)framePcmBytes
    frameByteCount:(NSUInteger)frameByteCount;
- (bool)writeFrame:(uint8_t *_Nullable)framePcmBytes
    frameByteCount:(NSUInteger)frameByteCount
       endOfStream:(bool)endOfStream;
- (NSUInteger)encodedBytes;
- (NSTimeInterval)encodedDuration;

- (NSDictionary *)pause;
- (bool)resumeWithDataItem:(DataItem *)dataItem
              encoderState:(NSDictionary *)state;

@end

NS_ASSUME_NONNULL_END

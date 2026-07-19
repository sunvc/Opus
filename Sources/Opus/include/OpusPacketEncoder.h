#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OpusPacketEncoderApplication) {
  OpusPacketEncoderApplicationVoip,
  OpusPacketEncoderApplicationAudio,
};

@interface OpusPacketEncoder : NSObject

@property(nonatomic, readonly) NSInteger inputSampleRate;
@property(nonatomic, readonly) NSInteger codingRate;
@property(nonatomic, readonly) NSInteger bitrate;
@property(nonatomic, readonly) NSInteger frameSize;
@property(nonatomic, readonly) NSInteger frameByteCount;
@property(nonatomic, readonly) NSTimeInterval encodedDuration;
@property(nonatomic, readonly) NSUInteger encodedPackets;

- (nullable instancetype)initWithInputSampleRate:(NSInteger)inputSampleRate
                                         bitrate:(NSInteger)bitrate
                                     application:
                                         (OpusPacketEncoderApplication)application
    NS_DESIGNATED_INITIALIZER;

- (nullable NSData *)encodeFrame:(uint8_t *_Nullable)framePcmBytes
                  frameByteCount:(NSUInteger)frameByteCount
                     endOfStream:(bool)endOfStream;

- (void)resetState;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

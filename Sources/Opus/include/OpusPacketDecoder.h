#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpusPacketDecoder : NSObject

@property(nonatomic, readonly) NSInteger sampleRate;
@property(nonatomic, readonly) NSInteger defaultFrameSize;

- (nullable instancetype)initWithSampleRate:(NSInteger)sampleRate
    NS_DESIGNATED_INITIALIZER;

- (nullable NSData *)decodePacket:(NSData *_Nullable)packet
                        frameSize:(NSInteger)frameSize
                        decodeFEC:(bool)decodeFEC;

- (void)resetState;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

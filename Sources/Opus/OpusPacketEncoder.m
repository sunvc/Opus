#import "include/OpusPacketEncoder.h"

#include "../libopus/libopus.xcframework/macos-arm64_x86_64/Headers/opus/opus.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int OpusPacketSupportedCodingRate(NSInteger inputSampleRate) {
  switch (inputSampleRate) {
  case 8000:
  case 12000:
  case 16000:
  case 24000:
  case 48000:
    return (int)inputSampleRate;
  default:
    return 0;
  }
}

static int OpusPacketApplicationValue(OpusPacketEncoderApplication application) {
  return application == OpusPacketEncoderApplicationVoip
             ? OPUS_APPLICATION_VOIP
             : OPUS_APPLICATION_AUDIO;
}

@interface OpusPacketEncoder () {
  OpusEncoder *_encoder;
  uint8_t *_packetBuffer;
  int _maxPacketBytes;
  int _applicationValue;
  opus_int64 _encodedSamples;
  NSUInteger _encodedPackets;
}

@end

@implementation OpusPacketEncoder

- (nullable instancetype)initWithInputSampleRate:(NSInteger)inputSampleRate
                                         bitrate:(NSInteger)targetBitrate
                                     application:
                                         (OpusPacketEncoderApplication)application {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  NSInteger resolvedSampleRate = inputSampleRate > 0 ? inputSampleRate : 48000;
  int supportedCodingRate = OpusPacketSupportedCodingRate(resolvedSampleRate);
  if (supportedCodingRate == 0) {
    return nil;
  }

  _inputSampleRate = resolvedSampleRate;
  _codingRate = supportedCodingRate;
  _bitrate = targetBitrate > 0 ? targetBitrate : 30 * 1024;
  _frameSize = _codingRate / 50;
  _frameByteCount = _frameSize * (NSInteger)sizeof(opus_int16);
  _applicationValue = OpusPacketApplicationValue(application);
  _maxPacketBytes = 1275;

  int result = OPUS_OK;
  _encoder =
      opus_encoder_create((opus_int32)_codingRate, 1, _applicationValue, &result);
  if (result != OPUS_OK || _encoder == NULL) {
    return nil;
  }

  _packetBuffer = malloc((size_t)_maxPacketBytes);
  if (_packetBuffer == NULL) {
    opus_encoder_destroy(_encoder);
    _encoder = NULL;
    return nil;
  }

  result = opus_encoder_ctl(_encoder, OPUS_SET_BITRATE((opus_int32)_bitrate));
  if (result != OPUS_OK) {
    [self cleanup];
    return nil;
  }

#ifdef OPUS_SET_LSB_DEPTH
  result = opus_encoder_ctl(_encoder, OPUS_SET_LSB_DEPTH(16));
  if (result != OPUS_OK) {
    [self cleanup];
    return nil;
  }
#endif

  return self;
}

- (void)dealloc {
  [self cleanup];
#if !__has_feature(objc_arc)
  [super dealloc];
#endif
}

- (void)cleanup {
  if (_encoder != NULL) {
    opus_encoder_destroy(_encoder);
    _encoder = NULL;
  }

  if (_packetBuffer != NULL) {
    free(_packetBuffer);
    _packetBuffer = NULL;
  }
}

- (NSData *)encodeFrame:(uint8_t *)framePcmBytes
         frameByteCount:(NSUInteger)frameByteCount
            endOfStream:(bool)endOfStream {
  if (_encoder == NULL) {
    return nil;
  }

  if (framePcmBytes == NULL || frameByteCount == 0) {
    return endOfStream ? [NSData data] : nil;
  }

  opus_int32 sampleCount = (opus_int32)(frameByteCount / sizeof(opus_int16));
  if (sampleCount <= 0 || sampleCount > _frameSize) {
    return nil;
  }

  uint8_t *pcmBytes = framePcmBytes;
  bool shouldFreePCMBytes = false;
  if (sampleCount < _frameSize) {
    pcmBytes = malloc((size_t)_frameByteCount);
    if (pcmBytes == NULL) {
      return nil;
    }

    shouldFreePCMBytes = true;
    memcpy(pcmBytes, framePcmBytes, frameByteCount);
    memset(pcmBytes + frameByteCount, 0, (size_t)_frameByteCount - frameByteCount);
  }

  int encodedByteCount = opus_encode(_encoder, (const opus_int16 *)pcmBytes,
                                     (int)_frameSize, _packetBuffer,
                                     _maxPacketBytes);
  if (shouldFreePCMBytes) {
    free(pcmBytes);
  }

  if (encodedByteCount < 0) {
    return nil;
  }

  _encodedSamples += sampleCount;
  _encodedPackets += 1;
  return [NSData dataWithBytes:_packetBuffer length:(NSUInteger)encodedByteCount];
}

- (NSTimeInterval)encodedDuration {
  if (_codingRate <= 0) {
    return 0;
  }

  return _encodedSamples / (NSTimeInterval)_codingRate;
}

- (NSUInteger)encodedPackets {
  return _encodedPackets;
}

- (void)resetState {
  if (_encoder == NULL) {
    return;
  }

  opus_encoder_ctl(_encoder, OPUS_RESET_STATE);
  _encodedSamples = 0;
  _encodedPackets = 0;
}

@end

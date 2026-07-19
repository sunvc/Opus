#import "include/OpusPacketDecoder.h"

#include "../libopus/libopus.xcframework/macos-arm64_x86_64/Headers/opus/opus.h"
#include <stdint.h>
#include <stdlib.h>

static int OpusPacketDecoderSupportedRate(NSInteger sampleRate) {
  switch (sampleRate) {
  case 8000:
  case 12000:
  case 16000:
  case 24000:
  case 48000:
    return (int)sampleRate;
  default:
    return 0;
  }
}

@interface OpusPacketDecoder () {
  OpusDecoder *_decoder;
}

@end

@implementation OpusPacketDecoder

- (nullable instancetype)initWithSampleRate:(NSInteger)targetSampleRate {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  NSInteger resolvedSampleRate = targetSampleRate > 0 ? targetSampleRate : 48000;
  int supportedSampleRate = OpusPacketDecoderSupportedRate(resolvedSampleRate);
  if (supportedSampleRate == 0) {
    return nil;
  }

  _sampleRate = resolvedSampleRate;
  _defaultFrameSize = resolvedSampleRate / 50;

  int result = OPUS_OK;
  _decoder = opus_decoder_create((opus_int32)_sampleRate, 1, &result);
  if (result != OPUS_OK || _decoder == NULL) {
    return nil;
  }

  return self;
}

- (void)dealloc {
  if (_decoder != NULL) {
    opus_decoder_destroy(_decoder);
    _decoder = NULL;
  }
#if !__has_feature(objc_arc)
  [super dealloc];
#endif
}

- (NSData *)decodePacket:(NSData *)packet
               frameSize:(NSInteger)frameSize
               decodeFEC:(bool)decodeFEC {
  if (_decoder == NULL) {
    return nil;
  }

  int resolvedFrameSize = (int)(frameSize > 0 ? frameSize : _defaultFrameSize);
  const unsigned char *packetBytes = NULL;
  opus_int32 packetLength = 0;

  if (packet.length > 0) {
    packetBytes = packet.bytes;
    packetLength = (opus_int32)packet.length;

    if (frameSize <= 0) {
      resolvedFrameSize =
          opus_packet_get_nb_samples(packetBytes, packetLength, (opus_int32)_sampleRate);
      if (resolvedFrameSize <= 0) {
        return nil;
      }
    }
  }

  if (resolvedFrameSize <= 0) {
    return nil;
  }

  size_t pcmBufferLength = (size_t)resolvedFrameSize * sizeof(opus_int16);
  opus_int16 *pcmBuffer = malloc(pcmBufferLength);
  if (pcmBuffer == NULL) {
    return nil;
  }

  int decodedSampleCount =
      opus_decode(_decoder, packetBytes, packetLength, pcmBuffer,
                  resolvedFrameSize, decodeFEC ? 1 : 0);
  if (decodedSampleCount < 0) {
    free(pcmBuffer);
    return nil;
  }

  NSData *pcmData =
      [NSData dataWithBytes:pcmBuffer
                     length:(NSUInteger)decodedSampleCount * sizeof(opus_int16)];
  free(pcmBuffer);
  return pcmData;
}

- (void)resetState {
  if (_decoder == NULL) {
    return;
  }

  opus_decoder_ctl(_decoder, OPUS_RESET_STATE);
}

@end

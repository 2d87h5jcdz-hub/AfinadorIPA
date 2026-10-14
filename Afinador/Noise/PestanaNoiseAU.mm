#import "PestanaNoiseAU.h"

#include <atomic>
#include <memory>
#include <vector>

#include "NoiseReducer.h"

namespace {
constexpr int kLiveFFT = 512;
constexpr int kOfflineFFT = 2048;
struct NoiseScratch {
  std::vector<float> channels[2];
  std::atomic<bool> bypass{false};
};
} // namespace

@interface PestanaNoiseAU () {
  std::unique_ptr<pestana::NoiseReducer> _core;
  std::unique_ptr<NoiseScratch> _scratch;
  AUAudioUnitBus *_inputBus;
  AUAudioUnitBus *_outputBus;
  AUAudioUnitBusArray *_inputBusArray;
  AUAudioUnitBusArray *_outputBusArray;
  double _rate;
}
@end

@implementation PestanaNoiseAU

+ (AudioComponentDescription)pestanaComponentDescription {
  AudioComponentDescription d = {};
  d.componentType = kAudioUnitType_Effect;
  d.componentSubType = 0x6e6f6973;       // 'nois'
  d.componentManufacturer = 0x5073746e;  // 'Pstn'
  return d;
}

+ (void)registerIfNeeded {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [AUAudioUnit registerSubclass:self
           asComponentDescription:[self pestanaComponentDescription]
                             name:@"Pestana: Ruído"
                          version:1];
  });
}

+ (NSInteger)liveFFTSize { return kLiveFFT; }

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
  self = [super initWithComponentDescription:componentDescription options:options error:outError];
  if (self == nil) return nil;
  _core = std::make_unique<pestana::NoiseReducer>(kLiveFFT);
  _scratch = std::make_unique<NoiseScratch>();
  _rate = 48000;
  AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
  _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
  _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
  if (_inputBus == nil || _outputBus == nil) return nil;
  _inputBus.maximumChannelCount = 2;
  _outputBus.maximumChannelCount = 2;
  _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                          busType:AUAudioUnitBusTypeInput
                                                           busses:@[ _inputBus ]];
  _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                           busType:AUAudioUnitBusTypeOutput
                                                            busses:@[ _outputBus ]];
  self.maximumFramesToRender = 4096;
  return self;
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (BOOL)canProcessInPlace { return YES; }
- (NSArray<NSNumber *> *)channelCapabilities { return @[ @(-1), @(-1) ]; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
  if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
  _rate = _outputBus.format.sampleRate;
  _core->prepare(_rate);
  const size_t maxFrames = (size_t)self.maximumFramesToRender;
  for (int ch = 0; ch < 2; ch++) _scratch->channels[ch].assign(maxFrames, 0.0f);
  return YES;
}

- (AUInternalRenderBlock)internalRenderBlock {
  pestana::NoiseReducer *core = _core.get();
  NoiseScratch *scratch = _scratch.get();
  return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                            AUAudioFrameCount frameCount, NSInteger outputBusNumber,
                            AudioBufferList *outputData, const AURenderEvent *realtimeEventListHead,
                            AURenderPullInputBlock pullInputBlock) {
    if (pullInputBlock == nil) return kAudioUnitErr_NoConnection;
    const UInt32 buffers = outputData->mNumberBuffers;
    if (buffers == 0) return noErr;
    if (outputData->mBuffers[0].mData == nullptr) {
      for (UInt32 i = 0; i < buffers && i < 2; i++) {
        if (scratch->channels[i].size() < frameCount) return kAudioUnitErr_TooManyFramesToProcess;
        outputData->mBuffers[i].mData = scratch->channels[i].data();
        outputData->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
      }
    }
    AudioUnitRenderActionFlags pullFlags = 0;
    const AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
    if (status != noErr) return status;
    if (scratch->bypass.load()) return noErr;
    float *channels[2] = {nullptr, nullptr};
    int count = 0;
    for (UInt32 i = 0; i < buffers && i < 2; i++) {
      if (outputData->mBuffers[i].mData != nullptr) channels[count++] = (float *)outputData->mBuffers[i].mData;
    }
    if (count > 0) core->process(channels, count, (int)frameCount);
    return noErr;
  };
}

- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect {
  [super setShouldBypassEffect:shouldBypassEffect];
  _scratch->bypass.store(shouldBypassEffect);
}

- (void)setAmount:(float)amount { _core->setAmount(amount); }

- (void)setProfile:(nullable NSArray<NSNumber *> *)profile {
  if (profile == nil || profile.count == 0) { _core->clearProfile(); return; }
  std::vector<float> p(profile.count);
  for (NSUInteger i = 0; i < profile.count; i++) p[i] = profile[i].floatValue;
  _core->setProfile(p.data(), (int)p.size());
}

- (void)startLearningSeconds:(double)seconds { _core->startLearning(seconds); }
- (BOOL)isLearning { return _core->isLearning() ? YES : NO; }
- (BOOL)hasProfile { return _core->hasProfile() ? YES : NO; }
- (double)sampleRate { return _rate; }
- (NSInteger)latencySamples { return _core->latency(); }

- (nullable NSArray<NSNumber *> *)currentProfile {
  std::vector<float> p((size_t)_core->bins());
  const int n = _core->copyProfile(p.data(), (int)p.size());
  if (n <= 0) return nil;
  NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
  for (int i = 0; i < n; i++) [out addObject:@(p[(size_t)i])];
  return out;
}

+ (void)denoiseChannels:(NSArray<NSMutableData *> *)channels
             sampleRate:(double)sampleRate
                 amount:(float)amount
         learnedProfile:(nullable NSArray<NSNumber *> *)learned
            learnedRate:(double)learnedRate {
  if (channels.count == 0) return;
  pestana::NoiseReducer nr(kOfflineFFT);
  nr.prepare(sampleRate);
  nr.setAmount(amount);
  std::vector<std::vector<float>> work;
  for (NSMutableData *data in channels) {
    const float *src = (const float *)data.bytes;
    const size_t n = data.length / sizeof(float);
    work.emplace_back(src, src + n);
    if (work.size() == 2) break;
  }
  std::vector<float> profile;
  if (learned != nil && learned.count > 1 && learnedRate > 0) {
    std::vector<float> l(learned.count);
    for (NSUInteger i = 0; i < learned.count; i++) l[i] = learned[i].floatValue;
    profile = nr.convertProfile(l, (int)(learned.count - 1) * 2, learnedRate, sampleRate);
  } else {
    profile = nr.estimateProfile(work);
  }
  nr.setProfile(profile.data(), (int)profile.size());
  nr.processOffline(work);
  for (size_t c = 0; c < work.size(); c++) {
    NSMutableData *data = channels[c];
    memcpy(data.mutableBytes, work[c].data(), MIN(data.length, work[c].size() * sizeof(float)));
  }
}

@end

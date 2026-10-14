#import "PestanaLooperAU.h"

#include <memory>
#include <vector>

#include "LooperCore.h"

namespace {
constexpr double kMaxBaseSeconds = 60.0;
struct LooperScratch {
  std::vector<float> channels[2];
};
} // namespace

@interface PestanaLooperAU () {
  std::unique_ptr<pestana::LooperCore> _core;
  std::unique_ptr<LooperScratch> _scratch;
  AUAudioUnitBus *_inputBus;
  AUAudioUnitBus *_outputBus;
  AUAudioUnitBusArray *_inputBusArray;
  AUAudioUnitBusArray *_outputBusArray;
  double _preparedRate;
}
@end

@implementation PestanaLooperAU

+ (AudioComponentDescription)pestanaComponentDescription {
  AudioComponentDescription d = {};
  d.componentType = kAudioUnitType_Effect;
  d.componentSubType = 0x6c6f6f70;       // 'loop'
  d.componentManufacturer = 0x5073746e;  // 'Pstn'
  return d;
}

+ (void)registerIfNeeded {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [AUAudioUnit registerSubclass:self
           asComponentDescription:[self pestanaComponentDescription]
                             name:@"Pestana: Loop"
                          version:1];
  });
}

+ (NSInteger)maxTracks { return pestana::LooperCore::kMaxTracks; }

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
  self = [super initWithComponentDescription:componentDescription options:options error:outError];
  if (self == nil) return nil;
  _core = std::make_unique<pestana::LooperCore>();
  _scratch = std::make_unique<LooperScratch>();
  _preparedRate = 0;
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
- (NSArray<NSNumber *> *)channelCapabilities { return @[ @(2), @(2) ]; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
  if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
  const double rate = _outputBus.format.sampleRate;
  // Os loops sobrevivem a um reinício do motor (troca de fone etc.) se a taxa não mudar.
  if (rate != _preparedRate) {
    _core->prepare(rate, kMaxBaseSeconds);
    _preparedRate = rate;
  }
  const size_t maxFrames = (size_t)self.maximumFramesToRender;
  for (int ch = 0; ch < 2; ch++) _scratch->channels[ch].assign(maxFrames, 0.0f);
  return YES;
}

- (AUInternalRenderBlock)internalRenderBlock {
  pestana::LooperCore *core = _core.get();
  LooperScratch *scratch = _scratch.get();
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
    float *left = (float *)outputData->mBuffers[0].mData;
    float *right = buffers > 1 && outputData->mBuffers[1].mData ? (float *)outputData->mBuffers[1].mData : left;
    if (left == nullptr) return noErr;
    // Processa no lugar: o núcleo lê a amostra de entrada antes de escrever a de saída.
    const float *in[2] = {left, right};
    float *out[2] = {left, right};
    if (right == left) {
      // Mono: a saída da direita vai para o rascunho e é descartada.
      if (scratch->channels[1].size() < frameCount) return kAudioUnitErr_TooManyFramesToProcess;
      out[1] = scratch->channels[1].data();
    }
    core->process(in, out, (int)frameCount);
    return noErr;
  };
}

- (void)setLatencySamples:(NSInteger)samples { _core->setLatencySamples((int)samples); }
- (void)setMonitor:(BOOL)on { _core->setMonitor(on); }
- (void)setVolume:(float)volume forTrack:(NSInteger)track { _core->setTrackVolume((int)track, volume); }
- (void)setMultiplier:(NSInteger)multiplier forTrack:(NSInteger)track {
  _core->setTrackMultiplier((int)track, (int)multiplier);
}
- (NSInteger)multiplierForTrack:(NSInteger)track { return _core->trackMultiplier((int)track); }

- (BOOL)pressTrack:(NSInteger)track { return _core->press((int)track) ? YES : NO; }
- (void)toggleMuteTrack:(NSInteger)track { _core->toggleMute((int)track); }
- (void)undoTrack:(NSInteger)track { _core->undo((int)track); }
- (void)clearTrack:(NSInteger)track { _core->clearTrack((int)track); }
- (void)stopAll { _core->stopAll(); }
- (void)playAll { _core->playAll(); }
- (void)clearAll { _core->clearAll(); }
- (void)collectGarbage { _core->collectGarbage(); }

- (PestanaLoopTrackState)stateForTrack:(NSInteger)track {
  return (PestanaLoopTrackState)_core->trackState((int)track);
}
- (BOOL)isTrackMuted:(NSInteger)track { return _core->trackMuted((int)track) ? YES : NO; }
- (BOOL)canUndoTrack:(NSInteger)track { return _core->trackCanUndo((int)track) ? YES : NO; }
- (float)progressForTrack:(NSInteger)track { return _core->trackProgress((int)track); }
- (float)levelForTrack:(NSInteger)track { return _core->trackLevel((int)track); }
- (double)lengthSecondsForTrack:(NSInteger)track {
  return (double)_core->trackLength((int)track) / _core->sampleRate();
}
- (double)baseSeconds { return (double)_core->baseLength() / _core->sampleRate(); }
- (double)positionSeconds { return (double)_core->position() / _core->sampleRate(); }
- (BOOL)isPlaying { return _core->playing() ? YES : NO; }
- (BOOL)hasContent { return _core->anyContent() ? YES : NO; }
- (float)inputLevel { return _core->inputLevel(); }

@end

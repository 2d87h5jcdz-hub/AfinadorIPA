#import "PestanaGuitarAU.h"

#include <memory>
#include <string>
#include <vector>

#include "GuitarFXCore.h"

namespace {
/// Buffers próprios para quando o host pede que o AU forneça a memória de saída.
struct RenderScratch {
  std::vector<float> channels[2];
};
} // namespace

@interface PestanaGuitarAU () {
  std::unique_ptr<pestana::GuitarFXCore> _core;
  std::unique_ptr<RenderScratch> _scratch;
  AUAudioUnitBus *_inputBus;
  AUAudioUnitBus *_outputBus;
  AUAudioUnitBusArray *_inputBusArray;
  AUAudioUnitBusArray *_outputBusArray;
}
@end

@implementation PestanaGuitarAU

+ (AudioComponentDescription)pestanaComponentDescription {
  AudioComponentDescription d = {};
  d.componentType = kAudioUnitType_Effect;
  d.componentSubType = 0x67746678;       // 'gtfx'
  d.componentManufacturer = 0x5073746e;  // 'Pstn'
  d.componentFlags = 0;
  d.componentFlagsMask = 0;
  return d;
}

+ (void)registerIfNeeded {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [AUAudioUnit registerSubclass:self
           asComponentDescription:[self pestanaComponentDescription]
                             name:@"Pestana: Guitarra"
                          version:1];
  });
}

+ (nullable NSString *)validateModelAtPath:(NSString *)path {
  pestana::GuitarFXCore core;
  core.prepare(48000.0, 512, 1);
  std::string error;
  if (core.loadModel(std::string(path.fileSystemRepresentation), error)) return nil;
  return [NSString stringWithUTF8String:error.c_str()] ?: @"arquivo inválido";
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
  self = [super initWithComponentDescription:componentDescription options:options error:outError];
  if (self == nil) return nil;
  _core = std::make_unique<pestana::GuitarFXCore>();
  _scratch = std::make_unique<RenderScratch>();
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
  AVAudioFormat *format = _outputBus.format;
  const int maxFrames = (int)self.maximumFramesToRender;
  _core->prepare(format.sampleRate, maxFrames, (int)format.channelCount);
  for (int ch = 0; ch < 2; ch++) _scratch->channels[ch].assign((size_t)maxFrames, 0.0f);
  return YES;
}

- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect {
  [super setShouldBypassEffect:shouldBypassEffect];
  _core->setBypass(shouldBypassEffect);
}

- (AUInternalRenderBlock)internalRenderBlock {
  pestana::GuitarFXCore *core = _core.get();
  RenderScratch *scratch = _scratch.get();
  return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                            AUAudioFrameCount frameCount, NSInteger outputBusNumber,
                            AudioBufferList *outputData, const AURenderEvent *realtimeEventListHead,
                            AURenderPullInputBlock pullInputBlock) {
    if (pullInputBlock == nil) return kAudioUnitErr_NoConnection;
    const UInt32 buffers = outputData->mNumberBuffers;
    if (buffers == 0) return noErr;
    // Host sem memória de saída: usa a nossa.
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
    float *channels[2] = {nullptr, nullptr};
    int count = 0;
    for (UInt32 i = 0; i < buffers && i < 2; i++) {
      if (outputData->mBuffers[i].mData != nullptr) channels[count++] = (float *)outputData->mBuffers[i].mData;
    }
    if (count > 0) core->process(channels, count, (int)frameCount);
    return noErr;
  };
}

- (BOOL)loadAmpModelAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error {
  std::string message;
  const bool ok = _core->loadModel(std::string(path.fileSystemRepresentation), message);
  if (!ok && error != nil) *error = [NSString stringWithUTF8String:message.c_str()];
  return ok ? YES : NO;
}

- (void)clearAmpModel { _core->clearModel(); }

- (BOOL)hasAmpModel { return _core->hasModel() ? YES : NO; }

- (void)setAmpInputDB:(float)inputDB outputDB:(float)outputDB { _core->setAmpGains(inputDB, outputDB); }

- (void)setDriveStyle:(NSInteger)style amount:(float)amount { _core->setDrive((int)style, amount); }

- (BOOL)hasDrive { return _core->driveActive() ? YES : NO; }

- (void)setModulationType:(NSInteger)type rate:(float)rate depth:(float)depth mix:(float)mix {
  _core->setModulation((int)type, rate, depth, mix);
}

@end

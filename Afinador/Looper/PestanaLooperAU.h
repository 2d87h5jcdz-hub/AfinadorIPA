// Audio Unit (v3, dentro do app) do Loop: grava a entrada (já com efeitos) em faixas sincronizadas
// e devolve entrada (se o retorno estiver ligado) + loops. Toda a lógica está no LooperCore (C++).
// Todos os métodos abaixo: só na thread principal.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PestanaLoopTrackState) {
  PestanaLoopTrackStateEmpty = 0,
  PestanaLoopTrackStateRecording = 1,
  PestanaLoopTrackStatePlaying = 2,
  PestanaLoopTrackStateOverdubbing = 3,
};

@interface PestanaLooperAU : AUAudioUnit

+ (AudioComponentDescription)pestanaComponentDescription;
+ (void)registerIfNeeded;
@property (class, nonatomic, readonly) NSInteger maxTracks;

- (void)setLatencySamples:(NSInteger)samples;
- (void)setMonitor:(BOOL)on;
- (void)setVolume:(float)volume forTrack:(NSInteger)track;
- (void)setMultiplier:(NSInteger)multiplier forTrack:(NSInteger)track;
- (NSInteger)multiplierForTrack:(NSInteger)track;

/// false = não deu agora (ex.: ainda fechando a gravação anterior); tente de novo em alguns ms.
- (BOOL)pressTrack:(NSInteger)track;
- (void)toggleMuteTrack:(NSInteger)track;
- (void)undoTrack:(NSInteger)track;
- (void)clearTrack:(NSInteger)track;
- (void)stopAll;
- (void)playAll;
- (void)clearAll;
- (void)collectGarbage;

- (PestanaLoopTrackState)stateForTrack:(NSInteger)track;
- (BOOL)isTrackMuted:(NSInteger)track;
- (BOOL)canUndoTrack:(NSInteger)track;
- (float)progressForTrack:(NSInteger)track;
- (float)levelForTrack:(NSInteger)track;
- (double)lengthSecondsForTrack:(NSInteger)track;
@property (nonatomic, readonly) double baseSeconds;
@property (nonatomic, readonly) double positionSeconds;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL hasContent;
@property (nonatomic, readonly) float inputLevel;

@end

NS_ASSUME_NONNULL_END

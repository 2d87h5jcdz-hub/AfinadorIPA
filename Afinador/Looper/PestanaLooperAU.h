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
  /// Modo automático: espera o próximo início de ciclo (ou a contagem / a primeira nota).
  PestanaLoopTrackStateArmed = 4,
};

typedef NS_ENUM(NSInteger, PestanaLoopPhase) {
  PestanaLoopPhaseNone = 0,
  PestanaLoopPhaseCountIn = 1,
  PestanaLoopPhaseWaitingSound = 2,
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

/// Modo automático. startOnSound: começa na primeira nota (senão, um compasso de contagem).
- (void)setAutoEnabled:(BOOL)enabled bars:(NSInteger)bars startOnSound:(BOOL)startOnSound
                 chain:(BOOL)chain gapCycles:(NSInteger)gap trackCount:(NSInteger)count;
- (void)setTempoBPM:(double)bpm beatsPerBar:(NSInteger)beats;
- (void)setClickDuringLoop:(BOOL)on volume:(float)volume;
- (void)setTriggerLevel:(float)level;
@property (nonatomic, readonly) double autoCycleSeconds;
@property (nonatomic, readonly) PestanaLoopPhase phase;
@property (nonatomic, readonly) NSInteger currentBeat;

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

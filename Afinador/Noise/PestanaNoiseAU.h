// Audio Unit (v3, dentro do app) de redução de ruído ao vivo (NoiseReducer, FFT 512 ≈ 10,7 ms),
// e funções para limpar uma gravação inteira no Estúdio (FFT 2048, sem atraso).
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface PestanaNoiseAU : AUAudioUnit

+ (AudioComponentDescription)pestanaComponentDescription;
+ (void)registerIfNeeded;
/// Tamanho de FFT do tempo real (o perfil aprendido tem fftSize/2 + 1 valores).
@property (class, nonatomic, readonly) NSInteger liveFFTSize;

// Thread principal.
- (void)setAmount:(float)amount;
- (void)setProfile:(nullable NSArray<NSNumber *> *)profile;
- (void)startLearningSeconds:(double)seconds;
@property (nonatomic, readonly) BOOL isLearning;
@property (nonatomic, readonly) BOOL hasProfile;
- (nullable NSArray<NSNumber *> *)currentProfile;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger latencySamples;

/// Limpa a gravação inteira, no lugar. channels: um NSMutableData de Float32 por canal.
/// learned: perfil aprendido ao vivo (opcional, com a taxa em que foi aprendido); sem ele, o perfil
/// é estimado dos trechos mais silenciosos da própria gravação.
+ (void)denoiseChannels:(NSArray<NSMutableData *> *)channels
             sampleRate:(double)sampleRate
                 amount:(float)amount
         learnedProfile:(nullable NSArray<NSNumber *> *)learned
            learnedRate:(double)learnedRate;

@end

NS_ASSUME_NONNULL_END

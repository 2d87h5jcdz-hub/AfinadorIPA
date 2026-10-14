// Audio Unit (v3, dentro do app) do bloco "Guitarra": amplificador neural (NAM) + modulação.
// Entra na cadeia de efeitos do Estúdio como um AVAudioUnitEffect comum.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface PestanaGuitarAU : AUAudioUnit

+ (AudioComponentDescription)pestanaComponentDescription;
/// Registra a classe no sistema (uma vez). Chamar antes de criar o AVAudioUnitEffect.
+ (void)registerIfNeeded;
/// Confere se um arquivo .nam abre; nil = ok, senão a mensagem de erro.
+ (nullable NSString *)validateModelAtPath:(NSString *)path;

/// Fora da thread de áudio.
- (BOOL)loadAmpModelAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error;
- (void)clearAmpModel;
@property (nonatomic, readonly) BOOL hasAmpModel;

- (void)setAmpInputDB:(float)inputDB outputDB:(float)outputDB;
/// style: 0 distorção, 1 crunch, 2 funk, 3 fuzz. amount 0 desliga o drive.
- (void)setDriveStyle:(NSInteger)style amount:(float)amount;
@property (nonatomic, readonly) BOOL hasDrive;
/// type: 0 nenhum, 1 chorus, 2 flanger, 3 phaser, 4 tremolo.
- (void)setModulationType:(NSInteger)type rate:(float)rate depth:(float)depth mix:(float)mix;

@end

NS_ASSUME_NONNULL_END

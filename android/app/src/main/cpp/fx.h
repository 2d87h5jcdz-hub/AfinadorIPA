// Cadeia de efeitos de uma faixa do Estúdio (e do retorno ao vivo), em C++ puro.
// Ordem (igual ao iOS): noise gate → EQ 3 bandas → compressor → drive → guitarra (amp NAM +
// modulação, GuitarFXCore) → delay → reverb. Thread de áudio: só process().
#pragma once
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace pestana {

class GuitarFXCore;

struct FxParams {
  bool gateEnabled = false;
  float gateThresholdDB = -50;
  float eqLowDB = 0, eqMidDB = 0, eqHighDB = 0;
  bool compressorEnabled = false;
  float compressorAmount = 0.5f;
  float driveAmount = 0;
  int driveStyle = 0;  // 0 distorção, 1 crunch, 2 funk, 3 fuzz
  float delayMix = 0, delayTime = 0.35f, delayFeedback = 0.3f;
  float reverbMix = 0;
  std::string ampModel;  // caminho absoluto do .nam ("" = sem amp)
  float ampInputDB = 0, ampOutputDB = 0;
  int modType = 0;
  float modRate = 0.6f, modDepth = 0.5f, modMix = 0.5f;

  bool isNeutral() const;
};

struct Biquad {
  float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  float z1[2] = {0, 0}, z2[2] = {0, 0};
  void lowShelf(double sr, double f, double db);
  void highShelf(double sr, double f, double db);
  void peak(double sr, double f, double db, double q);
  void reset() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
  inline float run(float x, int ch) {
    float y = b0 * x + z1[ch];
    z1[ch] = b1 * x - a1 * y + z2[ch];
    z2[ch] = b2 * x - a2 * y;
    return y;
  }
};

/// Reverb tipo Freeverb (8 combs + 4 allpass por canal), sala média.
class Reverb {
 public:
  void prepare(double sr);
  void process(float* l, float* r, int n, float mix);
  void reset();
 private:
  struct Comb { std::vector<float> buf; int idx = 0; float store = 0; };
  struct Allpass { std::vector<float> buf; int idx = 0; };
  Comb combs[2][8];
  Allpass aps[2][4];
  bool ready = false;
};

class FxChain {
 public:
  FxChain();
  ~FxChain();
  /// Fora da thread de áudio.
  void prepare(double sampleRate, int maxFrames);
  /// Fora da thread de áudio: aplica parâmetros (carrega o amp .nam se mudou).
  void setParams(const FxParams& p);
  /// Thread de áudio: processa no lugar (estéreo, não intercalado).
  void process(float* l, float* r, int n);
  void reset();
  /// Último erro ao carregar o amp (para a interface).
  std::string ampError();

 private:
  void applyPending();

  std::mutex mMutex;
  FxParams mPending;
  bool mDirty = false;
  std::string mAmpError;

  FxParams mP;  // cópia usada pela thread de áudio
  double mSr = 48000;
  int mMaxFrames = 1024;
  Biquad mLow, mMid, mHigh;
  bool mEqOn = false;
  float mGateGain = 1, mGateEnv = 0;
  float mCompEnv = 0;
  std::vector<float> mDelay[2];
  int mDelayIdx = 0;
  Reverb mReverb;
  std::unique_ptr<GuitarFXCore> mGuitar;
  std::string mLoadedAmp;
  float mLpState[2] = {0, 0};
};

}  // namespace pestana

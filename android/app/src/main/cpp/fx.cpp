#include "fx.h"

#include <algorithm>
#include <cmath>

#include "GuitarFXCore.h"

namespace pestana {

namespace {
constexpr double kPi = 3.141592653589793;
inline float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }
inline float clampf(float v, float lo, float hi) { return std::min(hi, std::max(lo, v)); }
}  // namespace

bool FxParams::isNeutral() const {
  return !gateEnabled && eqLowDB == 0 && eqMidDB == 0 && eqHighDB == 0 && !compressorEnabled &&
         driveAmount <= 0 && delayMix <= 0 && reverbMix <= 0 && ampModel.empty() && modType == 0;
}

// --- Biquads (RBJ cookbook)

void Biquad::lowShelf(double sr, double f, double db) {
  double A = std::pow(10.0, db / 40.0), w = 2 * kPi * f / sr, c = std::cos(w), s = std::sin(w);
  double alpha = s / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * alpha;
  double a0 = (A + 1) + (A - 1) * c + sq;
  b0 = float(A * ((A + 1) - (A - 1) * c + sq) / a0);
  b1 = float(2 * A * ((A - 1) - (A + 1) * c) / a0);
  b2 = float(A * ((A + 1) - (A - 1) * c - sq) / a0);
  a1 = float(-2 * ((A - 1) + (A + 1) * c) / a0);
  a2 = float(((A + 1) + (A - 1) * c - sq) / a0);
}

void Biquad::highShelf(double sr, double f, double db) {
  double A = std::pow(10.0, db / 40.0), w = 2 * kPi * f / sr, c = std::cos(w), s = std::sin(w);
  double alpha = s / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * alpha;
  double a0 = (A + 1) - (A - 1) * c + sq;
  b0 = float(A * ((A + 1) + (A - 1) * c + sq) / a0);
  b1 = float(-2 * A * ((A - 1) + (A + 1) * c) / a0);
  b2 = float(A * ((A + 1) + (A - 1) * c - sq) / a0);
  a1 = float(2 * ((A - 1) - (A + 1) * c) / a0);
  a2 = float(((A + 1) - (A - 1) * c - sq) / a0);
}

void Biquad::peak(double sr, double f, double db, double q) {
  double A = std::pow(10.0, db / 40.0), w = 2 * kPi * f / sr, c = std::cos(w), s = std::sin(w);
  double alpha = s / (2 * q);
  double a0 = 1 + alpha / A;
  b0 = float((1 + alpha * A) / a0);
  b1 = float(-2 * c / a0);
  b2 = float((1 - alpha * A) / a0);
  a1 = float(-2 * c / a0);
  a2 = float((1 - alpha / A) / a0);
}

// --- Reverb

void Reverb::prepare(double sr) {
  static const int combT[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
  static const int apT[4] = {556, 441, 341, 225};
  const double k = sr / 44100.0;
  for (int ch = 0; ch < 2; ch++) {
    const int spread = ch ? 23 : 0;
    for (int i = 0; i < 8; i++) {
      combs[ch][i].buf.assign(size_t((combT[i] + spread) * k) + 1, 0.0f);
      combs[ch][i].idx = 0;
      combs[ch][i].store = 0;
    }
    for (int i = 0; i < 4; i++) {
      aps[ch][i].buf.assign(size_t((apT[i] + spread) * k) + 1, 0.0f);
      aps[ch][i].idx = 0;
    }
  }
  ready = true;
}

void Reverb::reset() {
  for (auto& side : combs)
    for (auto& c : side) { std::fill(c.buf.begin(), c.buf.end(), 0.0f); c.store = 0; }
  for (auto& side : aps)
    for (auto& a : side) std::fill(a.buf.begin(), a.buf.end(), 0.0f);
}

void Reverb::process(float* l, float* r, int n, float mix) {
  if (!ready || mix <= 0) return;
  const float feedback = 0.84f, damp = 0.25f, gain = 0.015f;
  float* chans[2] = {l, r};
  for (int i = 0; i < n; i++) {
    const float input = (l[i] + r[i]) * gain;
    for (int ch = 0; ch < 2; ch++) {
      float out = 0;
      for (auto& c : combs[ch]) {
        float y = c.buf[c.idx];
        c.store = y * (1 - damp) + c.store * damp;
        c.buf[c.idx] = input + c.store * feedback;
        if (++c.idx >= int(c.buf.size())) c.idx = 0;
        out += y;
      }
      for (auto& a : aps[ch]) {
        float b = a.buf[a.idx];
        a.buf[a.idx] = out + b * 0.5f;
        out = b - out;
        if (++a.idx >= int(a.buf.size())) a.idx = 0;
      }
      chans[ch][i] = chans[ch][i] * (1 - mix * 0.5f) + out * mix * 3.0f;
    }
  }
}

// --- FxChain

FxChain::FxChain() : mGuitar(std::make_unique<GuitarFXCore>()) {}
FxChain::~FxChain() = default;

void FxChain::prepare(double sampleRate, int maxFrames) {
  mSr = sampleRate;
  mMaxFrames = maxFrames;
  for (auto& d : mDelay) d.assign(size_t(sampleRate * 2.1), 0.0f);
  mDelayIdx = 0;
  mReverb.prepare(sampleRate);
  mGuitar->prepare(sampleRate, maxFrames, 2);
  std::lock_guard<std::mutex> g(mMutex);
  mDirty = true;
}

void FxChain::reset() {
  mLow.reset(); mMid.reset(); mHigh.reset();
  for (auto& d : mDelay) std::fill(d.begin(), d.end(), 0.0f);
  mReverb.reset();
  mGateEnv = 0; mGateGain = 1; mCompEnv = 0;
  mLpState[0] = mLpState[1] = 0;
}

void FxChain::setParams(const FxParams& p) {
  // O .nam é carregado aqui (fora da thread de áudio).
  if (p.ampModel != mLoadedAmp) {
    std::string err;
    if (p.ampModel.empty()) {
      mGuitar->clearModel();
    } else if (!mGuitar->loadModel(p.ampModel, err)) {
      mGuitar->clearModel();
    }
    std::lock_guard<std::mutex> g(mMutex);
    mAmpError = err;
    mLoadedAmp = p.ampModel;
  }
  mGuitar->setAmpGains(p.ampInputDB, p.ampOutputDB);
  mGuitar->setModulation(p.modType, p.modRate, p.modDepth, p.modMix);
  std::lock_guard<std::mutex> g(mMutex);
  mPending = p;
  mDirty = true;
}

std::string FxChain::ampError() {
  std::lock_guard<std::mutex> g(mMutex);
  return mAmpError;
}

void FxChain::applyPending() {
  std::unique_lock<std::mutex> g(mMutex, std::try_to_lock);
  if (!g.owns_lock() || !mDirty) return;
  mP = mPending;
  mDirty = false;
  mLow.lowShelf(mSr, 100, mP.eqLowDB);
  mMid.peak(mSr, 1000, mP.eqMidDB, 0.9);
  mHigh.highShelf(mSr, 8000, mP.eqHighDB);
  mEqOn = mP.eqLowDB != 0 || mP.eqMidDB != 0 || mP.eqHighDB != 0;
}

void FxChain::process(float* l, float* r, int n) {
  applyPending();
  const FxParams& p = mP;
  float* ch[2] = {l, r};

  // Noise gate (envelope de pico, ataque rápido, soltura de ~80 ms)
  if (p.gateEnabled) {
    const float th = dbToGain(clampf(p.gateThresholdDB, -90, 0));
    const float rel = std::exp(-1.0f / float(0.08 * mSr));
    const float att = std::exp(-1.0f / float(0.001 * mSr));
    for (int i = 0; i < n; i++) {
      float a = std::max(std::fabs(l[i]), std::fabs(r[i]));
      mGateEnv = a > mGateEnv ? a : mGateEnv * rel;
      float target = mGateEnv > th ? 1.0f : 0.0f;
      mGateGain = target > mGateGain ? target + (mGateGain - target) * att : target + (mGateGain - target) * rel;
      l[i] *= mGateGain; r[i] *= mGateGain;
    }
  }

  if (mEqOn) {
    for (int c = 0; c < 2; c++)
      for (int i = 0; i < n; i++) ch[c][i] = mHigh.run(mMid.run(mLow.run(ch[c][i], c), c), c);
  }

  // Compressor (amount 0…1 → limiar −10…−34 dB, razão 2…6, ganho de compensação)
  if (p.compressorEnabled) {
    const float amt = clampf(p.compressorAmount, 0, 1);
    const float thDB = -10 - 24 * amt, ratio = 2 + 4 * amt;
    // Compensação moderada (≈ 1/4 da redução máxima): antes era o dobro e a voz estourava.
    const float makeup = dbToGain(std::min(6.0f, -thDB * (1 - 1 / ratio) * 0.25f));
    const float att = std::exp(-1.0f / float(0.005 * mSr)), rel = std::exp(-1.0f / float(0.12 * mSr));
    for (int i = 0; i < n; i++) {
      float a = std::max(std::fabs(l[i]), std::fabs(r[i]));
      mCompEnv = a > mCompEnv ? a + (mCompEnv - a) * att : a + (mCompEnv - a) * rel;
      float envDB = 20 * std::log10(mCompEnv + 1e-9f);
      float gr = envDB > thDB ? (thDB - envDB) * (1 - 1 / ratio) : 0;
      float g = dbToGain(gr) * makeup;
      l[i] *= g; r[i] *= g;
    }
  }

  // Drive: 4 estilos de saturação + filtro de tom suave
  if (p.driveAmount > 0) {
    const float amt = clampf(p.driveAmount, 0, 1);
    const float pre = 1 + amt * (p.driveStyle == 3 ? 60 : 30);
    const float post = 1.0f / std::sqrt(pre) * (p.driveStyle == 3 ? 0.6f : 0.9f);
    const float lpA = std::exp(-2 * float(kPi) * 6500.0f / float(mSr));
    for (int c = 0; c < 2; c++) {
      for (int i = 0; i < n; i++) {
        float x = ch[c][i] * pre, y;
        switch (p.driveStyle) {
          case 1: y = x > 0 ? std::tanh(x) : std::tanh(x * 0.7f) / 0.7f * 0.8f; break;  // crunch: assimétrico
          case 2: y = x / (1 + std::fabs(x)); break;                                      // funk: macio
          case 3: y = clampf(x, -0.5f, 0.5f) * 2; break;                                   // fuzz: corte duro
          default: y = std::tanh(x); break;                                                // distorção
        }
        mLpState[c] = y + (mLpState[c] - y) * lpA;
        ch[c][i] = mLpState[c] * post * (1 + amt);
      }
    }
  }

  // Guitarra: amp neural (.nam) + modulação
  if (!p.ampModel.empty() || p.modType != 0) {
    int off = 0;
    while (off < n) {
      int k = std::min(n - off, mMaxFrames);
      float* io[2] = {l + off, r + off};
      mGuitar->process(io, 2, k);
      off += k;
    }
  }

  // Delay (eco) com realimentação
  if (p.delayMix > 0) {
    const int len = int(mDelay[0].size());
    const int d = std::clamp(int(clampf(p.delayTime, 0.02f, 2.0f) * mSr), 1, len - 1);
    const float fb = clampf(p.delayFeedback, 0, 0.9f), mix = clampf(p.delayMix, 0, 1);
    for (int i = 0; i < n; i++) {
      int rd = mDelayIdx - d;
      if (rd < 0) rd += len;
      for (int c = 0; c < 2; c++) {
        float y = mDelay[c][size_t(rd)];
        mDelay[c][size_t(mDelayIdx)] = ch[c][i] + y * fb;
        ch[c][i] += y * mix;
      }
      if (++mDelayIdx >= len) mDelayIdx = 0;
    }
  }

  if (p.reverbMix > 0) mReverb.process(l, r, n, clampf(p.reverbMix, 0, 1));

  for (int i = 0; i < n; i++) {
    if (!std::isfinite(l[i])) l[i] = 0;
    if (!std::isfinite(r[i])) r[i] = 0;
  }
}

}  // namespace pestana

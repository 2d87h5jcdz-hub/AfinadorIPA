#include "GuitarFXCore.h"

#include <algorithm>
#include <cmath>
#include <exception>
#include <filesystem>

#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

namespace pestana {

namespace {
constexpr double kTwoPi = 6.283185307179586;
constexpr float kMaxDelaySeconds = 0.05f;   // 50 ms: chorus/flanger cabem com folga
constexpr float kTargetLoudnessDB = -18.0f; // nível de saída padronizado dos modelos

inline float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }
inline float clampf(float v, float lo, float hi) { return std::min(hi, std::max(lo, v)); }
} // namespace

GuitarFXCore::GuitarFXCore() = default;
GuitarFXCore::~GuitarFXCore() = default;

void GuitarFXCore::prepare(double sampleRate, int maxFrames, int channels) {
  mSampleRate = sampleRate > 0 ? sampleRate : 48000.0;
  mMaxFrames = std::max(64, maxFrames);
  mChannels = std::max(1, std::min(channels, kMaxChannels));
  mMono.assign(static_cast<size_t>(mMaxFrames), 0.0f);
  mAmpOut.assign(static_cast<size_t>(mMaxFrames), 0.0f);
  const size_t delayLength = static_cast<size_t>(mSampleRate * kMaxDelaySeconds) + 4;
  for (int ch = 0; ch < kMaxChannels; ch++) {
    mDelay[ch].assign(delayLength, 0.0f);
    for (int s = 0; s < 4; s++) mAllpass[ch][s] = 0.0f;
    mPhaserFeedback[ch] = 0.0f;
    mDriveState[ch] = DriveChannel();
  }
  mDelayWrite = 0;
  if (nam::DSP* model = mModel.load()) {
    model->Reset(mSampleRate, mMaxFrames);
  }
}

bool GuitarFXCore::loadModel(const std::string& path, std::string& error) {
  try {
    std::unique_ptr<nam::DSP> model = nam::get_dsp(std::filesystem::path(path));
    if (!model) {
      error = "modelo vazio";
      return false;
    }
    model->Reset(mSampleRate, mMaxFrames);
    float norm = 1.0f;
    if (model->HasLoudness()) {
      norm = dbToGain(kTargetLoudnessDB - static_cast<float>(model->GetLoudness()));
    }
    nam::DSP* raw = model.get();
    // Modelos antigos ficam guardados (a thread de áudio pode estar no meio de um bloco com eles);
    // só os de duas trocas atrás são liberados.
    while (mOwned.size() > 2) mOwned.erase(mOwned.begin());
    mOwned.push_back(std::move(model));
    mNormGain.store(clampf(norm, 0.01f, 30.0f));
    mModel.store(raw);
    return true;
  } catch (const std::exception& e) {
    error = e.what();
  } catch (...) {
    error = "erro desconhecido ao ler o modelo";
  }
  return false;
}

void GuitarFXCore::clearModel() { mModel.store(nullptr); }

void GuitarFXCore::setAmpGains(float inputDB, float outputDB) {
  mInputGain.store(dbToGain(clampf(inputDB, -24.0f, 24.0f)));
  mOutputGain.store(dbToGain(clampf(outputDB, -24.0f, 24.0f)));
}

void GuitarFXCore::setModulation(int type, float rateHz, float depth, float mix) {
  mModType.store(type);
  mModRate.store(clampf(rateHz, 0.02f, 12.0f));
  mModDepth.store(clampf(depth, 0.0f, 1.0f));
  mModMix.store(clampf(mix, 0.0f, 1.0f));
}

void GuitarFXCore::setDrive(int style, float amount) {
  mDriveStyle.store(std::max(0, std::min(style, 3)));
  mDriveAmount.store(clampf(amount, 0.0f, 1.0f));
}

namespace {
struct DriveVoice {
  float minGainDB, maxGainDB;  // ganho antes do saturador (amount 0 → 1)
  float highPassHz;            // tira grave embolado antes de saturar
  float toneHz;                // passa-baixas depois (corta o chiado das harmônicas altas)
  float level;                 // nível de saída
};
inline DriveVoice driveVoice(int style) {
  switch (style) {
    case DriveCrunch: return {4.0f, 30.0f, 90.0f, 6500.0f, 0.42f};
    case DriveFunk:   return {0.0f, 18.0f, 160.0f, 8000.0f, 0.70f};
    case DriveFuzz:   return {18.0f, 50.0f, 60.0f, 3600.0f, 0.34f};
    default:          return {10.0f, 44.0f, 110.0f, 5200.0f, 0.34f};
  }
}
/// Curvas de saturação. Todas comprimem: quanto mais a nota cai, mais ganho relativo ela recebe,
/// que é o que dá sustentação (o oposto de x² / x³, que encurtava a nota).
inline float shape(int style, float x) {
  switch (style) {
    case DriveCrunch: {
      // Assimétrica: o lado negativo satura antes (harmônicas pares, timbre de válvula).
      return x >= 0.0f ? std::tanh(x) : std::tanh(1.6f * x) / 1.6f;
    }
    case DriveFunk:
      return x / (1.0f + std::fabs(x));
    case DriveFuzz: {
      const float bias = 0.3f;
      float y = std::tanh(1.5f * (x + bias)) - std::tanh(1.5f * bias);
      return clampf(y, -0.75f, 0.75f) / 0.75f;
    }
    default:
      return std::tanh(x);
  }
}
} // namespace

void GuitarFXCore::processDrive(float* const* channels, int nch, int frames) {
  const int style = mDriveStyle.load();
  const float amount = mDriveAmount.load();
  const DriveVoice v = driveVoice(style);
  const float targetGain = dbToGain(v.minGainDB + (v.maxGainDB - v.minGainDB) * amount);
  const float targetLevel = v.level;
  const float sr = static_cast<float>(mSampleRate);
  const float hpA = std::exp(-static_cast<float>(kTwoPi) * v.highPassHz / sr);
  const float lpA = 1.0f - std::exp(-static_cast<float>(kTwoPi) * v.toneHz / sr);
  const float dcR = 0.995f;
  const float smooth = 1.0f - std::exp(-1.0f / (0.02f * sr));   // ~20 ms

  float g = mDriveGainSmoothed, lv = mDriveLevelSmoothed;
  for (int i = 0; i < frames; i++) {
    g += (targetGain - g) * smooth;
    lv += (targetLevel - lv) * smooth;
    for (int ch = 0; ch < nch; ch++) {
      DriveChannel& st = mDriveState[ch];
      const float x = channels[ch][i];
      // passa-altas de 1 polo
      const float hp = hpA * (st.hpY + x - st.hpX);
      st.hpX = x; st.hpY = hp;
      // 2x: satura a amostra do meio e a atual e tira a média (reduz aliasing das harmônicas)
      const float mid = 0.5f * (st.prev + hp);
      st.prev = hp;
      float y = 0.5f * (shape(style, g * mid) + shape(style, g * hp));
      // tom
      st.lp1 += lpA * (y - st.lp1);
      st.lp2 += lpA * (st.lp1 - st.lp2);
      y = st.lp2;
      // bloqueio de DC (curvas assimétricas geram DC)
      const float dc = y - st.dcX + dcR * st.dcY;
      st.dcX = y; st.dcY = dc;
      float out = dc * lv;
      if (!std::isfinite(out)) { out = 0.0f; st = DriveChannel(); }
      channels[ch][i] = out;
    }
  }
  mDriveGainSmoothed = g;
  mDriveLevelSmoothed = lv;
}

void GuitarFXCore::process(float* const* channels, int numChannels, int frames) {
  if (mBypass.load() || numChannels <= 0 || frames <= 0) return;
  const int nch = std::min(numChannels, kMaxChannels);

  if (driveActive()) processDrive(channels, nch, frames);

  if (nam::DSP* model = mModel.load()) {
    const float inGain = mInputGain.load();
    const float outGain = mOutputGain.load() * mNormGain.load();
    int offset = 0;
    while (offset < frames) {
      const int n = std::min(frames - offset, mMaxFrames);
      for (int i = 0; i < n; i++) {
        float sum = 0.0f;
        for (int ch = 0; ch < nch; ch++) sum += channels[ch][offset + i];
        mMono[static_cast<size_t>(i)] = sum / static_cast<float>(nch) * inGain;
      }
      float* in = mMono.data();
      float* out = mAmpOut.data();
      model->process(&in, &out, n);
      for (int i = 0; i < n; i++) {
        float v = mAmpOut[static_cast<size_t>(i)] * outGain;
        if (!std::isfinite(v)) v = 0.0f;
        v = clampf(v, -4.0f, 4.0f);
        for (int ch = 0; ch < nch; ch++) channels[ch][offset + i] = v;
      }
      offset += n;
    }
  }
  if (mModType.load() != ModNone) processModulation(channels, nch, frames);
}

void GuitarFXCore::processModulation(float* const* channels, int nch, int frames) {
  const int type = mModType.load();
  const float rate = mModRate.load();
  const float depth = mModDepth.load();
  const float mix = mModMix.load();
  const double sr = mSampleRate;
  const double phaseStep = rate / sr;
  const int length = static_cast<int>(mDelay[0].size());
  if (length < 4) return;

  for (int i = 0; i < frames; i++) {
    for (int ch = 0; ch < nch; ch++) {
      // Canal direito com o LFO defasado 90°: dá largura estéreo.
      const double phase = mLfoPhase + (ch == 1 ? 0.25 : 0.0);
      const float lfo = static_cast<float>(0.5 + 0.5 * std::sin(kTwoPi * phase)); // 0…1
      const float dry = channels[ch][i];
      float wet = dry;
      switch (type) {
      case ModChorus:
      case ModFlanger: {
        const bool flanger = type == ModFlanger;
        const float baseMs = flanger ? 1.0f : 14.0f;
        const float sweepMs = (flanger ? 4.0f : 8.0f) * depth;
        const float delaySamples = static_cast<float>((baseMs + sweepMs * lfo) * 0.001 * sr);
        float readPos = static_cast<float>(mDelayWrite) - delaySamples;
        while (readPos < 0) readPos += static_cast<float>(length);
        const int i0 = static_cast<int>(readPos);
        const int i1 = (i0 + 1) % length;
        const float frac = readPos - static_cast<float>(i0);
        std::vector<float>& line = mDelay[ch];
        const float delayed = line[static_cast<size_t>(i0)] * (1.0f - frac) + line[static_cast<size_t>(i1)] * frac;
        const float feedback = flanger ? 0.55f : 0.1f;
        float write = dry + delayed * feedback;
        if (!std::isfinite(write)) write = 0.0f;
        line[static_cast<size_t>(mDelayWrite)] = clampf(write, -4.0f, 4.0f);
        wet = delayed;
        break;
      }
      case ModPhaser: {
        // 4 passa-tudo de 1ª ordem com o centro varrendo 250 Hz … 2,5 kHz (exponencial).
        const float minHz = 250.0f, maxHz = 250.0f + 2250.0f * (0.3f + 0.7f * depth);
        const float hz = minHz * std::pow(maxHz / minHz, lfo);
        const float t = std::tan(static_cast<float>(M_PI) * hz / static_cast<float>(sr));
        const float a = (t - 1.0f) / (t + 1.0f);
        float x = dry + mPhaserFeedback[ch] * 0.4f;
        for (int s = 0; s < 4; s++) {
          const float y = a * x + mAllpass[ch][s];
          mAllpass[ch][s] = x - a * y;
          x = y;
        }
        if (!std::isfinite(x)) {
          x = 0.0f;
          for (int s = 0; s < 4; s++) mAllpass[ch][s] = 0.0f;
        }
        mPhaserFeedback[ch] = x;
        wet = x;
        break;
      }
      case ModTremolo: {
        wet = dry * (1.0f - depth * (1.0f - lfo));
        break;
      }
      default:
        break;
      }
      channels[ch][i] = type == ModTremolo ? (dry * (1.0f - mix) + wet * mix) : (dry * (1.0f - 0.5f * mix) + wet * mix * 0.7f);
    }
    if (type == ModChorus || type == ModFlanger) {
      // Canais sem dado neste quadro (mono) mantêm a linha andando igual.
      for (int ch = nch; ch < kMaxChannels; ch++) mDelay[ch][static_cast<size_t>(mDelayWrite)] = 0.0f;
      mDelayWrite = (mDelayWrite + 1) % length;
    }
    mLfoPhase += phaseStep;
    if (mLfoPhase >= 1.0) mLfoPhase -= 1.0;
  }
}

} // namespace pestana

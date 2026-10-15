#include "NoiseReducer.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace pestana {

namespace {
constexpr double kPi = 3.14159265358979323846;
inline float clampf(float v, float lo, float hi) { return std::min(hi, std::max(lo, v)); }
} // namespace

NoiseReducer::NoiseReducer(int fftSize) {
  int n = 64;
  while (n < fftSize && n < 8192) n <<= 1;
  mN = n;
  mHop = mN / 4;
  mWindow.resize(static_cast<size_t>(mN));
  for (int i = 0; i < mN; i++) {
    const double hann = 0.5 - 0.5 * std::cos(2.0 * kPi * i / mN);   // Hann periódica
    mWindow[static_cast<size_t>(i)] = static_cast<float>(std::sqrt(hann));
  }
  int bitsCount = 0;
  while ((1 << bitsCount) < mN) bitsCount++;
  mBitRev.resize(static_cast<size_t>(mN));
  for (int i = 0; i < mN; i++) {
    int r = 0;
    for (int b = 0; b < bitsCount; b++) if (i & (1 << b)) r |= 1 << (bitsCount - 1 - b);
    mBitRev[static_cast<size_t>(i)] = r;
  }
  mCos.resize(static_cast<size_t>(mN / 2));
  mSin.resize(static_cast<size_t>(mN / 2));
  for (int i = 0; i < mN / 2; i++) {
    mCos[static_cast<size_t>(i)] = static_cast<float>(std::cos(2.0 * kPi * i / mN));
    mSin[static_cast<size_t>(i)] = static_cast<float>(std::sin(2.0 * kPi * i / mN));
  }
  const size_t nb = static_cast<size_t>(bins());
  mProfile[0].assign(nb, 0.0f);
  mProfile[1].assign(nb, 0.0f);
  prepare(48000.0);
}

void NoiseReducer::prepare(double sampleRate) {
  mSampleRate = sampleRate > 0 ? sampleRate : 48000.0;
  const size_t n = static_cast<size_t>(mN);
  const size_t nb = static_cast<size_t>(bins());
  for (int c = 0; c < kMaxChannels; c++) {
    mInFifo[c].assign(n, 0.0f);
    mOutFifo[c].assign(n, 0.0f);
    mAccum[c].assign(2 * n, 0.0f);
    mRe[c].assign(n, 0.0f);
    mIm[c].assign(n, 0.0f);
  }
  mPower.assign(nb, 0.0f);
  mGain.assign(nb, 1.0f);
  mGainSmooth.assign(nb, 1.0f);
  mPowerSmooth.assign(nb, 0.0f);
  mLearnAcc.assign(nb, 0.0);
  mLearnFrames = 0;
  mRover = mN - mHop;
}

void NoiseReducer::reset() { prepare(mSampleRate); }

void NoiseReducer::setAmount(float amount) { mAmount.store(clampf(amount, 0.0f, 1.0f)); }

void NoiseReducer::setProfile(const float* profile, int count) {
  if (profile == nullptr || count <= 0) { clearProfile(); return; }
  const int inactive = 1 - mActive.load();
  std::vector<float>& dst = mProfile[inactive];
  for (int k = 0; k < bins(); k++) dst[static_cast<size_t>(k)] = k < count ? std::max(0.0f, profile[k]) : 0.0f;
  mActive.store(inactive);
  mHasProfile.store(true);
}

void NoiseReducer::clearProfile() { mHasProfile.store(false); }

void NoiseReducer::startLearning(double seconds) {
  const int frames = std::max(4, static_cast<int>(seconds * mSampleRate / mHop));
  mLearnFramesWanted.store(frames);
  mLearning.store(true);
}

int NoiseReducer::copyProfile(float* out, int max) const {
  if (!mHasProfile.load()) return 0;
  const std::vector<float>& p = mProfile[mActive.load()];
  const int n = std::min(max, bins());
  for (int k = 0; k < n; k++) out[k] = p[static_cast<size_t>(k)];
  return n;
}

// ---------------------------------------------------------------- FFT (radix 2)

void NoiseReducer::fft(std::vector<float>& re, std::vector<float>& im, bool inverse) const {
  const int n = mN;
  for (int i = 0; i < n; i++) {
    const int j = mBitRev[static_cast<size_t>(i)];
    if (j > i) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
  }
  for (int len = 2; len <= n; len <<= 1) {
    const int half = len >> 1;
    const int step = n / len;
    for (int i = 0; i < n; i += len) {
      for (int j = 0; j < half; j++) {
        const float wr = mCos[static_cast<size_t>(j * step)];
        const float wi = inverse ? mSin[static_cast<size_t>(j * step)] : -mSin[static_cast<size_t>(j * step)];
        const int a = i + j, b = i + j + half;
        const float tr = re[b] * wr - im[b] * wi;
        const float ti = re[b] * wi + im[b] * wr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr; im[a] += ti;
      }
    }
  }
}

// ---------------------------------------------------------------- tempo real

void NoiseReducer::process(float* const* channels, int numChannels, int frames) {
  const int nch = std::max(1, std::min(numChannels, kMaxChannels));
  const int lat = mN - mHop;   // início do FIFO (o atraso total é mN)
  for (int i = 0; i < frames; i++) {
    for (int c = 0; c < nch; c++) {
      mInFifo[c][static_cast<size_t>(mRover)] = channels[c][i];
      channels[c][i] = mOutFifo[c][static_cast<size_t>(mRover - lat)];
    }
    mRover++;
    if (mRover >= mN) {
      mRover = lat;
      processFrame(nch);
    }
  }
}

void NoiseReducer::processFrame(int nch) {
  const int n = mN;
  const int nb = bins();
  for (int c = 0; c < nch; c++) {
    for (int i = 0; i < n; i++) {
      mRe[c][static_cast<size_t>(i)] = mInFifo[c][static_cast<size_t>(i)] * mWindow[static_cast<size_t>(i)];
      mIm[c][static_cast<size_t>(i)] = 0.0f;
    }
    fft(mRe[c], mIm[c], false);
  }
  for (int k = 0; k < nb; k++) {
    float p = 0.0f;
    for (int c = 0; c < nch; c++) {
      const float r = mRe[c][static_cast<size_t>(k)], m = mIm[c][static_cast<size_t>(k)];
      p += r * r + m * m;
    }
    mPower[static_cast<size_t>(k)] = p / static_cast<float>(nch);
  }

  if (mLearning.load()) {
    for (int k = 0; k < nb; k++) mLearnAcc[static_cast<size_t>(k)] += mPower[static_cast<size_t>(k)];
    if (++mLearnFrames >= mLearnFramesWanted.load()) {
      const int inactive = 1 - mActive.load();
      for (int k = 0; k < nb; k++) {
        mProfile[inactive][static_cast<size_t>(k)] = static_cast<float>(mLearnAcc[static_cast<size_t>(k)] / mLearnFrames);
        mLearnAcc[static_cast<size_t>(k)] = 0.0;
      }
      mLearnFrames = 0;
      mActive.store(inactive);
      mHasProfile.store(true);
      mLearning.store(false);
    }
  }

  const float amount = mAmount.load();
  const bool reduce = mHasProfile.load() && amount > 0.001f;
  if (reduce) {
    const std::vector<float>& prof = mProfile[mActive.load()];
    const float alpha = 1.5f + 2.5f * amount;
    const float floorGain = std::pow(10.0f, -(8.0f + 27.0f * amount) / 20.0f);
    const float release = static_cast<float>(std::exp(-mHop / (mSampleRate * 0.06)));
    // Potência suavizada no tempo (sobe na hora, desce em ~20 ms) e entre faixas vizinhas:
    // a potência de um ruído oscila muito de um quadro para outro e deixaria "chiadinhos".
    const float fall = static_cast<float>(std::exp(-mHop / (mSampleRate * 0.02)));
    for (int k = 0; k < nb; k++) {
      const float raw = 0.25f * mPower[static_cast<size_t>(std::max(0, k - 1))] + 0.5f * mPower[static_cast<size_t>(k)] +
                        0.25f * mPower[static_cast<size_t>(std::min(nb - 1, k + 1))];
      float& ps = mPowerSmooth[static_cast<size_t>(k)];
      ps = raw > ps ? raw : ps * fall + raw * (1.0f - fall);
    }
    for (int k = 0; k < nb; k++) {
      const float p = mPowerSmooth[static_cast<size_t>(k)];
      float g = 1.0f - alpha * prof[static_cast<size_t>(k)] / (p + 1e-20f);
      g = std::max(floorGain, g);
      float& s = mGainSmooth[static_cast<size_t>(k)];
      s = g > s ? g : s * release + g * (1.0f - release);
    }
    for (int k = 0; k < nb; k++) {
      const float a = mGainSmooth[static_cast<size_t>(std::max(0, k - 1))];
      const float b = mGainSmooth[static_cast<size_t>(k)];
      const float c = mGainSmooth[static_cast<size_t>(std::min(nb - 1, k + 1))];
      mGain[static_cast<size_t>(k)] = 0.25f * a + 0.5f * b + 0.25f * c;
    }
    for (int c = 0; c < nch; c++) {
      for (int k = 0; k < nb; k++) {
        const float g = mGain[static_cast<size_t>(k)];
        mRe[c][static_cast<size_t>(k)] *= g;
        mIm[c][static_cast<size_t>(k)] *= g;
        if (k > 0 && k < n / 2) {
          mRe[c][static_cast<size_t>(n - k)] *= g;
          mIm[c][static_cast<size_t>(n - k)] *= g;
        }
      }
    }
  } else {
    std::fill(mGainSmooth.begin(), mGainSmooth.end(), 1.0f);
  }

  // Síntese: janela de novo e soma com sobreposição. Σ Hann com passo N/4 = 2 → escala 0,5; IFFT → 1/N.
  const float scale = 0.5f / static_cast<float>(n);
  for (int c = 0; c < nch; c++) {
    fft(mRe[c], mIm[c], true);
    std::vector<float>& acc = mAccum[c];
    for (int i = 0; i < n; i++) acc[static_cast<size_t>(i)] += mRe[c][static_cast<size_t>(i)] * mWindow[static_cast<size_t>(i)] * scale;
    for (int i = 0; i < mHop; i++) mOutFifo[c][static_cast<size_t>(i)] = acc[static_cast<size_t>(i)];
    std::memmove(acc.data(), acc.data() + mHop, sizeof(float) * static_cast<size_t>(n));
    std::fill(acc.begin() + n, acc.end(), 0.0f);
    std::memmove(mInFifo[c].data(), mInFifo[c].data() + mHop, sizeof(float) * static_cast<size_t>(n - mHop));
  }
}

// ---------------------------------------------------------------- fora de tempo real

std::vector<float> NoiseReducer::estimateProfile(const std::vector<std::vector<float>>& channels) const {
  const int nb = bins();
  std::vector<float> profile(static_cast<size_t>(nb), 0.0f);
  if (channels.empty() || channels[0].size() < static_cast<size_t>(mN)) return profile;
  const int nch = std::min(static_cast<int>(channels.size()), kMaxChannels);
  const int64_t len = static_cast<int64_t>(channels[0].size());
  const int hop = mN / 2;

  // 1ª passada: energia de cada quadro.
  std::vector<std::pair<double, int64_t>> energy;
  for (int64_t start = 0; start + mN <= len; start += hop) {
    double e = 0.0;
    for (int c = 0; c < nch; c++) {
      const float* x = channels[static_cast<size_t>(c)].data() + start;
      for (int i = 0; i < mN; i++) e += static_cast<double>(x[i]) * x[i];
    }
    e /= static_cast<double>(mN * nch);
    // Ignora silêncio digital e fades quase mudos (< −75 dBFS): não são o ruído do ambiente.
    if (e > 3e-8) energy.push_back({e, start});
  }
  if (energy.empty()) return profile;
  std::sort(energy.begin(), energy.end());
  const size_t take = std::max<size_t>(std::min<size_t>(8, energy.size()), energy.size() / 10);

  // 2ª passada: espectro médio dos quadros mais baixos.
  std::vector<float> re(static_cast<size_t>(mN)), im(static_cast<size_t>(mN));
  std::vector<double> acc(static_cast<size_t>(nb), 0.0);
  for (size_t f = 0; f < take; f++) {
    const int64_t start = energy[f].second;
    for (int c = 0; c < nch; c++) {
      const float* x = channels[static_cast<size_t>(c)].data() + start;
      for (int i = 0; i < mN; i++) { re[static_cast<size_t>(i)] = x[i] * mWindow[static_cast<size_t>(i)]; im[static_cast<size_t>(i)] = 0.0f; }
      fft(re, im, false);
      for (int k = 0; k < nb; k++) {
        acc[static_cast<size_t>(k)] += (static_cast<double>(re[static_cast<size_t>(k)]) * re[static_cast<size_t>(k)] +
                                        static_cast<double>(im[static_cast<size_t>(k)]) * im[static_cast<size_t>(k)]) / nch;
      }
    }
  }
  for (int k = 0; k < nb; k++) profile[static_cast<size_t>(k)] = static_cast<float>(acc[static_cast<size_t>(k)] / static_cast<double>(take));
  return profile;
}

void NoiseReducer::processOffline(std::vector<std::vector<float>>& channels) {
  if (channels.empty()) return;
  const int nch = std::min(static_cast<int>(channels.size()), kMaxChannels);
  const size_t len = channels[0].size();
  const int lat = latency();
  reset();
  std::vector<std::vector<float>> work(static_cast<size_t>(nch));
  for (int c = 0; c < nch; c++) {
    work[static_cast<size_t>(c)] = channels[static_cast<size_t>(c)];
    work[static_cast<size_t>(c)].resize(len + static_cast<size_t>(lat), 0.0f);
  }
  const size_t total = len + static_cast<size_t>(lat);
  const size_t chunk = 4096;
  for (size_t off = 0; off < total; off += chunk) {
    const int n = static_cast<int>(std::min(chunk, total - off));
    float* ptrs[kMaxChannels] = {nullptr, nullptr};
    for (int c = 0; c < nch; c++) ptrs[c] = work[static_cast<size_t>(c)].data() + off;
    process(ptrs, nch, n);
  }
  for (int c = 0; c < nch; c++) {
    std::copy(work[static_cast<size_t>(c)].begin() + lat, work[static_cast<size_t>(c)].begin() + lat + static_cast<long>(len),
              channels[static_cast<size_t>(c)].begin());
  }
}

std::vector<float> NoiseReducer::convertProfile(const std::vector<float>& profile, int fromFFT,
                                                double fromRate, double toRate) const {
  const int nb = bins();
  std::vector<float> out(static_cast<size_t>(nb), 0.0f);
  if (profile.empty() || fromFFT <= 0 || fromRate <= 0 || toRate <= 0) return out;
  const int fromBins = static_cast<int>(profile.size());
  const float scale = static_cast<float>(mN) / static_cast<float>(fromFFT);   // potência por faixa ∝ N
  for (int k = 0; k < nb; k++) {
    const double hz = k * toRate / mN;
    const double src = hz * fromFFT / fromRate;
    const int i0 = std::min(fromBins - 1, static_cast<int>(src));
    const int i1 = std::min(fromBins - 1, i0 + 1);
    const float t = static_cast<float>(src - i0);
    out[static_cast<size_t>(k)] = scale * ((1.0f - t) * profile[static_cast<size_t>(i0)] + t * profile[static_cast<size_t>(i1)]);
  }
  return out;
}

} // namespace pestana

// Redução de ruído por perfil espectral (C++ puro, testável fora do iOS).
//
// Feita para ruído quase constante: ar-condicionado, ventilador, chiado da interface, rua ao longe.
// 1. Perfil: a potência média do ruído em cada faixa de frequência, aprendida com o músico em
//    silêncio (ao vivo) ou estimada dos trechos mais baixos da gravação (no Estúdio).
// 2. A cada quadro (STFT, janela raiz de Hann, 75% de sobreposição) cada faixa de frequência recebe
//    um ganho g = max(piso, 1 − α·ruído/sinal): onde o instrumento está muito acima do ruído, g ≈ 1;
//    onde só há ruído, g = piso (não zera, para não soar artificial).
// 3. O ganho sobe na hora e desce suave (~60 ms) e é suavizado entre faixas vizinhas: evita o
//    "ruído musical" (chiadinhos borbulhando) típico da subtração espectral.
// O mesmo ganho vale para os dois canais (a imagem estéreo não muda).
//
// Threads: setAmount/setProfile/startLearning/copyProfile na principal; process() no áudio.
#pragma once
#include <atomic>
#include <cstdint>
#include <vector>

namespace pestana {

class NoiseReducer {
public:
  static constexpr int kMaxChannels = 2;

  explicit NoiseReducer(int fftSize = 512);

  int fftSize() const { return mN; }
  int bins() const { return mN / 2 + 1; }
  /// Atraso do processamento em tempo real, em amostras.
  int latency() const { return mN; }

  /// Fora da thread de áudio.
  void prepare(double sampleRate);
  void reset();

  /// 0…1: quanto tirar (α e profundidade do piso).
  void setAmount(float amount);
  /// Potência média do ruído por faixa (bins() valores, na escala deste tamanho de FFT).
  void setProfile(const float* profile, int count);
  void clearProfile();
  bool hasProfile() const { return mHasProfile.load(); }
  /// Aprende o perfil com os próximos `seconds` de entrada (o músico em silêncio).
  void startLearning(double seconds);
  bool isLearning() const { return mLearning.load(); }
  /// Copia o perfil atual. Retorna quantos valores copiou.
  int copyProfile(float* out, int max) const;

  /// Thread de áudio: processa no lugar (canais não intercalados). Sem perfil, só atrasa.
  void process(float* const* channels, int numChannels, int frames);

  // ---------- fora de tempo real (Estúdio) ----------
  /// Estima o perfil dos 10% de quadros mais silenciosos (ignorando silêncio digital).
  std::vector<float> estimateProfile(const std::vector<std::vector<float>>& channels) const;
  /// Processa o áudio inteiro, sem atraso na saída (compensa a latência).
  void processOffline(std::vector<std::vector<float>>& channels);
  /// Converte um perfil aprendido com outro tamanho de FFT / taxa para este.
  std::vector<float> convertProfile(const std::vector<float>& profile, int fromFFT,
                                    double fromRate, double toRate) const;

private:
  void processFrame(int numChannels);
  void fft(std::vector<float>& re, std::vector<float>& im, bool inverse) const;

  int mN, mHop;
  double mSampleRate = 48000.0;
  std::vector<float> mWindow;
  std::vector<int> mBitRev;
  std::vector<float> mCos, mSin;

  // perfil com troca atômica (escrito fora do áudio, lido no áudio)
  std::vector<float> mProfile[2];
  std::atomic<int> mActive{0};
  std::atomic<bool> mHasProfile{false};
  std::atomic<float> mAmount{0.5f};

  // aprendizado (acumulado no áudio)
  std::atomic<bool> mLearning{false};
  std::atomic<int> mLearnFramesWanted{0};
  std::vector<double> mLearnAcc;
  int mLearnFrames = 0;

  // estado do STFT em tempo real
  std::vector<float> mInFifo[kMaxChannels];
  std::vector<float> mOutFifo[kMaxChannels];
  std::vector<float> mAccum[kMaxChannels];
  int mRover = 0;
  std::vector<float> mRe[kMaxChannels], mIm[kMaxChannels];
  std::vector<float> mPower, mPowerSmooth, mGain, mGainSmooth;
};

} // namespace pestana

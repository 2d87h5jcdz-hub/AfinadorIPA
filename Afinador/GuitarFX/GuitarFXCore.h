// Núcleo do bloco "Guitarra" do Pestana Estúdio (C++ puro, testável fora do iOS).
// Amplificador neural (Neural Amp Modeler, MIT) + modulação (chorus, flanger, phaser, tremolo).
// Thread de áudio: só process(). Carregar/limpar modelo e prepare(): fora da thread de áudio.
#pragma once
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace nam { class DSP; }

namespace pestana {

enum ModType : int { ModNone = 0, ModChorus = 1, ModFlanger = 2, ModPhaser = 3, ModTremolo = 4 };

class GuitarFXCore {
public:
  GuitarFXCore();
  ~GuitarFXCore();

  /// Fora da thread de áudio. Reserva buffers e prepara o modelo carregado.
  void prepare(double sampleRate, int maxFrames, int channels);

  /// Fora da thread de áudio. Carrega um arquivo .nam; false + mensagem em caso de erro.
  bool loadModel(const std::string& path, std::string& error);
  void clearModel();
  bool hasModel() const { return mModel.load() != nullptr; }

  void setAmpGains(float inputDB, float outputDB);
  void setModulation(int type, float rateHz, float depth, float mix);
  void setBypass(bool bypass) { mBypass.store(bypass); }

  /// Thread de áudio: processa no lugar (canais não intercalados).
  void process(float* const* channels, int numChannels, int frames);

private:
  void processModulation(float* const* channels, int numChannels, int frames);

  std::atomic<nam::DSP*> mModel{nullptr};
  std::vector<std::unique_ptr<nam::DSP>> mOwned;     // modelos carregados (o ativo e os antigos)
  std::atomic<float> mInputGain{1.0f};
  std::atomic<float> mOutputGain{1.0f};
  std::atomic<float> mNormGain{1.0f};
  std::atomic<int> mModType{ModNone};
  std::atomic<float> mModRate{0.5f};
  std::atomic<float> mModDepth{0.5f};
  std::atomic<float> mModMix{0.5f};
  std::atomic<bool> mBypass{false};

  double mSampleRate = 48000.0;
  int mMaxFrames = 4096;
  int mChannels = 2;
  std::vector<float> mMono;
  std::vector<float> mAmpOut;

  // Modulação
  static constexpr int kMaxChannels = 2;
  std::vector<float> mDelay[kMaxChannels];
  int mDelayWrite = 0;
  double mLfoPhase = 0.0;
  float mAllpass[kMaxChannels][4] = {};
  float mPhaserFeedback[kMaxChannels] = {};
};

} // namespace pestana

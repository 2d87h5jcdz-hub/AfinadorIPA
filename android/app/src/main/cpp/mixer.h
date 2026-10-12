// Mixagem das faixas do Estúdio (C++ puro: usado pelo stream ao vivo e pela exportação).
// Áudio das faixas: arquivos PCM 16 bits estéreo intercalado a 48 kHz, mapeados em memória.
#pragma once
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "fx.h"

namespace pestana {

constexpr int kSampleRate = 48000;
constexpr int kMaxBlock = 2048;

/// Arquivo PCM mapeado (somente leitura).
class MappedPcm {
 public:
  static std::shared_ptr<MappedPcm> open(const std::string& path);
  ~MappedPcm();
  const int16_t* data = nullptr;  // L R L R …
  int64_t frames = 0;
 private:
  void* mBase = nullptr;
  size_t mSize = 0;
};

struct ClipRef {
  std::shared_ptr<MappedPcm> pcm;
  std::string path;
  int64_t offset = 0;     // início na linha do tempo (quadros)
  int64_t fileStart = 0;  // início dentro do arquivo
  int64_t duration = 0;   // quadros tocados
};

class TrackState {
 public:
  explicit TrackState(int64_t id);
  const int64_t id;
  std::vector<ClipRef> clips;
  std::atomic<float> volume{1}, pan{0};
  std::atomic<bool> mute{false}, solo{false}, fxOn{true};
  std::atomic<float> peak{0};
  FxChain fx;
  std::atomic<bool> hasFx{false};  // efeitos configurados (senão pula a cadeia)
};

/// Disposição imutável das faixas (trocada inteira quando a estrutura muda).
struct Song {
  std::vector<std::shared_ptr<TrackState>> tracks;
};

class Mixer {
 public:
  /// Soma as faixas em outL/outR (zerados aqui) a partir de songFrame (pode ser negativo).
  /// silenced = id da faixa que não toca (a armada durante a gravação), -1 = nenhuma.
  void render(const Song& song, int64_t songFrame, int n, float* outL, float* outR, int64_t silenced);
 private:
  float mL[kMaxBlock], mR[kMaxBlock];
};

/// Lê a disposição (JSON) e cria uma Song nova (os arquivos já mapeados são reaproveitados).
std::shared_ptr<Song> buildSong(const std::string& json, const Song* previous, double sampleRate, std::string& error);

/// Converte o JSON de efeitos (mesmos nomes do iOS) em FxParams. ampDir = pasta dos .nam.
FxParams parseFx(const std::string& json);

}  // namespace pestana

// Núcleo do Loop (pedaleira de loop) do Pestana Estúdio — C++ puro, testável fora do iOS.
//
// Modelo:
// - A primeira gravação define o CICLO (base). As outras faixas têm 1, 2 ou 4 ciclos e ficam
//   sempre sincronizadas pelo mesmo relógio (G = amostras desde o início do ciclo 0).
// - Cada faixa tem até três buffers estéreo: `main` (o que já foi consolidado), `layer` (a última
//   camada, que dá para desfazer) e `rec` (a camada sendo gravada). A reprodução soma os três.
// - Gravar de novo numa faixa que já toca = sobregravar (nova camada). Antes disso, a thread
//   principal junta `main + layer` num buffer novo e troca (o desfazer volta só a última camada).
// - Compensação de latência: a entrada que chega no instante G foi tocada ouvindo a posição
//   G − L (L = latência de ida e volta), então é escrita em G − L. Ao parar a gravação, a faixa
//   continua aceitando entrada por mais L amostras (a "cauda") para fechar o fim do ciclo.
//
// Threads: os métodos marcados [principal] só podem ser chamados de UMA thread (a principal);
// process() só da thread de áudio. A comunicação é por uma fila de comandos sem lock (SPSC) e
// por atomics de estado. Toda memória é alocada e liberada na thread principal.
#pragma once
#include <atomic>
#include <cstdint>
#include <vector>

namespace pestana {

class LooperCore {
public:
  static constexpr int kMaxTracks = 6;
  static constexpr int kChannels = 2;

  /// Estado lógico de cada faixa (o que a tela mostra).
  enum TrackState : int { Empty = 0, Recording = 1, Playing = 2, Overdubbing = 3 };

  LooperCore();
  ~LooperCore();
  LooperCore(const LooperCore&) = delete;
  LooperCore& operator=(const LooperCore&) = delete;

  // ---------- [principal] configuração ----------
  /// Com o áudio parado. Zera tudo (as gravações somem).
  void prepare(double sampleRate, double maxBaseSeconds);
  void setLatencySamples(int samples);
  void setMonitor(bool on) { mMonitor.store(on); }
  void setTrackVolume(int track, float volume);
  void setTrackMultiplier(int track, int multiplier);   // 1, 2 ou 4; só vale com a faixa vazia
  int trackMultiplier(int track) const;

  // ---------- [principal] ações (botões / pedal) ----------
  /// Botão da faixa: vazia → grava; gravando → toca (fecha o loop); tocando → sobregrava;
  /// sobregravando → toca. Se o ciclo base ainda está sendo gravado em outra faixa, só fecha o ciclo.
  /// false se não deu (ex.: memória insuficiente, ciclo ainda não informado pela thread de áudio).
  bool press(int track);
  /// Para/volta a faixa (mudo). Gravando, fecha a gravação antes.
  void toggleMute(int track);
  /// Desfaz a última camada (ou apaga a faixa se só houver a primeira gravação).
  void undo(int track);
  void clearTrack(int track);
  /// Para tudo (fecha gravações) / toca tudo do começo do ciclo.
  void stopAll();
  void playAll();
  void clearAll();
  /// Libera buffers devolvidos pela thread de áudio. Chamar periodicamente (ex.: no timer da tela).
  void collectGarbage();

  // ---------- [principal] leitura de estado ----------
  TrackState trackState(int track) const;
  bool trackMuted(int track) const;
  bool trackCanUndo(int track) const;
  /// Posição 0…1 dentro da faixa (para o anel de progresso).
  float trackProgress(int track) const;
  float trackLevel(int track) const;           // pico recente (0…1)
  int64_t trackLength(int track) const;        // amostras (0 = vazia)
  int64_t baseLength() const { return mBaseLen.load(); }
  bool playing() const { return mPlaying.load(); }
  int64_t position() const { return mPosition.load(); }
  float inputLevel() const { return mInputPeak.load(); }
  double sampleRate() const { return mSampleRate; }
  bool anyContent() const;

  // ---------- thread de áudio ----------
  /// in/out: kChannels canais não intercalados (podem ser o mesmo buffer).
  void process(const float* const* in, float* const* out, int frames);

private:
  struct Buffer {
    float* data = nullptr;   // planar: canal 0 em [0, cap), canal 1 em [cap, 2·cap)
    int64_t capacity = 0;
    float* ch(int c) const { return data + static_cast<size_t>(c) * static_cast<size_t>(capacity); }
  };

  enum CommandType : int {
    CmdStartRecord, CmdStopRecord, CmdSwapMain, CmdDropLayer, CmdClearTrack, CmdClearAll,
    CmdPlay, CmdStop, CmdMute,
  };
  struct Command {
    CommandType type;
    int track;
    Buffer buffer;      // StartRecord: buffer novo da camada; SwapMain: main + layer já somados
    int64_t length;     // StartRecord: comprimento da faixa (0 = gravando o ciclo base)
    bool flag;          // Mute
  };

  // Estado da faixa visto pela thread de áudio.
  struct AudioTrack {
    Buffer main, layer, rec;
    bool recording = false;
    int64_t tail = 0;           // amostras de cauda ainda a escrever depois de parar
    int64_t length = 0;         // 0 = vazia
    int64_t anchor = 0;         // início (em G) do primeiro ciclo da faixa
    bool muted = false;
    bool isBase = false;        // gravando o ciclo base (comprimento ainda indefinido)
    int64_t baseStartG = 0;
  };

  // Espelho na thread principal.
  struct MainTrack {
    TrackState state = Empty;
    int multiplier = 1;
    bool muted = false;
    Buffer main, layer, rec;    // ponteiros iguais aos da thread de áudio (para somar e liberar)
  };

  // fila de comandos (principal → áudio)
  static constexpr int kQueueSize = 256;
  Command mQueue[kQueueSize];
  std::atomic<int> mQueueHead{0}, mQueueTail{0};
  bool push(const Command& c);

  // fila de buffers devolvidos (áudio → principal)
  static constexpr int kRetireSize = 256;
  float* mRetire[kRetireSize] = {};
  std::atomic<int> mRetireHead{0}, mRetireTail{0};
  void retire(const Buffer& b);   // áudio
  void retire(float* p);

  void applyCommand(const Command& c);      // áudio
  void finishRecording(int t);              // áudio
  Buffer allocate(int64_t frames);          // principal
  void stopRecordingMain(int t);            // principal
  bool startRecordingMain(int t);           // principal
  bool mergeLayerMain(int t);               // principal

  double mSampleRate = 48000.0;
  int64_t mMaxBase = 0;
  int64_t mLatency = 0;
  std::atomic<bool> mMonitor{true};

  AudioTrack mAudio[kMaxTracks];
  MainTrack mMain[kMaxTracks];
  int mBaseTrack = -1;                      // [principal] faixa gravando o ciclo base

  // estado compartilhado (áudio escreve, principal lê)
  std::atomic<int64_t> mBaseLen{0};
  std::atomic<int64_t> mPosition{0};
  std::atomic<bool> mPlaying{false};
  std::atomic<int64_t> mTrackLen[kMaxTracks];
  std::atomic<int64_t> mTrackAnchor[kMaxTracks];
  std::atomic<bool> mTrackHasLayer[kMaxTracks];
  std::atomic<bool> mTrackBusy[kMaxTracks];     // gravando ou escrevendo a cauda
  std::atomic<float> mTrackPeak[kMaxTracks];
  std::atomic<float> mInputPeak{0.0f};
  std::atomic<float> mTrackVolume[kMaxTracks];

  // [áudio]
  int64_t mG = 0;
  bool mPlayingAudio = false;
};

} // namespace pestana

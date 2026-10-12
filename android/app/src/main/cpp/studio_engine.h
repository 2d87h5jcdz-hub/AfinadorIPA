// Motor de áudio do Estúdio no Android: Oboe (AAudio/OpenSL) em full duplex.
// Saída estéreo float + entrada mono float, ambas a 48 kHz, no mesmo callback: as faixas,
// o clique, o retorno ao vivo (com efeitos) e a gravação andam amostra a amostra juntos.
#pragma once
#include <oboe/Oboe.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "mixer.h"
#include "ring.h"

namespace pestana {

enum Transport : int { Stopped = 0, Playing = 1, CountIn = 2, Recording = 3 };

class StudioEngine : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
 public:
  StudioEngine();
  ~StudioEngine() override;

  /// Abre os streams. withInput = microfone liberado. Devolve "" ou a mensagem de erro.
  std::string open(bool withInput, int inputDeviceId = 0);
  void close();
  bool isOpen() const { return mOutput != nullptr; }
  bool hasInput() const { return mInput != nullptr; }

  std::string setSong(const std::string& json);
  void setTrackMix(int64_t id, float volume, float pan, bool mute, bool solo, bool fxOn);
  void setTrackFx(int64_t id, const std::string& json);
  void setMonitor(bool on, const std::string& fxJson);
  void setInputGainDB(float db);
  void setClick(double bpm, int beatsPerBar, bool clickOn);

  /// Começa a tocar (e a gravar em recordPath, se não vazio) a partir de fromFrame.
  std::string start(int64_t fromFrame, int64_t leadInFrames, const std::string& recordPath, int64_t silencedTrack);
  /// Para; devolve os quadros gravados (0 se não gravava).
  int64_t stop();

  int state() const { return mState.load(); }
  int64_t songFrame() const { return mSongFrame.load(); }
  int64_t recordedFrames() const { return mRecordedFrames.load(); }
  float takeInputPeak();
  /// Picos (0…1) das faixas, na ordem da disposição atual.
  std::vector<float> trackPeaks();
  double latencyMillis();
  std::string inputDeviceInfo();

  // Oboe
  oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream, void* audioData, int32_t numFrames) override;
  void onErrorAfterClose(oboe::AudioStream* stream, oboe::Result error) override;

 private:
  std::shared_ptr<Song> currentSong();
  void writerLoop();
  void renderClick(float* l, float* r, int n, int64_t songFrame);

  std::shared_ptr<oboe::AudioStream> mOutput, mInput;
  bool mWantInput = false;
  int mInputDevice = 0;
  std::mutex mStreamMutex;

  // Disposição: trocada pela UI; o callback pega com try_lock (nunca espera).
  std::mutex mSongMutex;
  std::shared_ptr<Song> mSong, mSongForAudio;
  std::vector<std::shared_ptr<Song>> mRetired;
  std::atomic<bool> mSongDirty{false};

  Mixer mMixer;
  std::atomic<int> mState{Stopped};
  std::atomic<int64_t> mSongFrame{0};
  std::atomic<int64_t> mRecordStart{0};
  std::atomic<int64_t> mSilenced{-1};
  std::atomic<bool> mRecording{false};
  std::atomic<int64_t> mRecordedFrames{0};

  // Clique
  std::atomic<double> mBpm{90};
  std::atomic<int> mBpb{4};
  std::atomic<bool> mClickOn{true};
  std::atomic<int64_t> mCountInEnd{INT64_MIN};
  int64_t mClickPos = 1 << 30;
  float mClickFreq = 1000, mClickAmp = 1;

  // Entrada / retorno
  std::atomic<float> mInputGain{1};
  std::atomic<bool> mMonitorOn{false};
  std::atomic<float> mInputPeak{0};
  FxChain mMonitorFx;
  std::atomic<bool> mMonitorHasFx{false};
  std::vector<float> mIn, mL, mR, mML, mMR;

  // Gravação
  FloatRing mRing{size_t(kSampleRate) * 20};
  std::thread mWriter;
  std::atomic<bool> mWriterRun{false};
  FILE* mRecordFile = nullptr;
  std::atomic<int64_t> mWrittenFrames{0};
};

/// Mixagem offline (exportação): mesma mistura e efeitos do ao vivo, mais rápido que o tempo real.
std::string renderOffline(const std::string& songJson, const std::string& outPath, int64_t totalFrames);

}  // namespace pestana

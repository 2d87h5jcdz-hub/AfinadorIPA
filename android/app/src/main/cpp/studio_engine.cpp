#include "studio_engine.h"

#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "PestanaStudio", __VA_ARGS__)

namespace pestana {

StudioEngine::StudioEngine() {
  mIn.resize(kMaxBlock);
  mL.resize(kMaxBlock);
  mR.resize(kMaxBlock);
  mML.resize(kMaxBlock);
  mMR.resize(kMaxBlock);
  mMonitorFx.prepare(kSampleRate, kMaxBlock);
}

StudioEngine::~StudioEngine() {
  stop();
  close();
}

std::string StudioEngine::open(bool withInput) {
  std::lock_guard<std::mutex> g(mStreamMutex);
  if (mOutput) {
    if (withInput == (mInput != nullptr)) return "";
    // Muda de "só saída" para duplex (ou o contrário): reabre.
    if (mInput) { mInput->stop(); mInput->close(); mInput.reset(); }
    mOutput->stop(); mOutput->close(); mOutput.reset();
  }
  mWantInput = withInput;
  oboe::AudioStreamBuilder ob;
  ob.setDirection(oboe::Direction::Output)
      ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
      ->setSharingMode(oboe::SharingMode::Exclusive)
      ->setFormat(oboe::AudioFormat::Float)
      ->setChannelCount(2)
      ->setSampleRate(kSampleRate)
      ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
      ->setUsage(oboe::Usage::Media)
      ->setContentType(oboe::ContentType::Music)
      ->setDataCallback(this)
      ->setErrorCallback(this);
  oboe::Result r = ob.openStream(mOutput);
  if (r != oboe::Result::OK) {
    mOutput.reset();
    return std::string("não consegui abrir a saída de áudio (") + oboe::convertToText(r) + ")";
  }
  // Buffer de 2 rajadas: baixa latência sem engasgar.
  mOutput->setBufferSizeInFrames(mOutput->getFramesPerBurst() * 2);

  if (withInput) {
    oboe::AudioStreamBuilder ib;
    ib.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setFormat(oboe::AudioFormat::Float)
        ->setChannelCount(1)
        ->setSampleRate(kSampleRate)
        ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
        ->setInputPreset(oboe::InputPreset::Unprocessed);
    r = ib.openStream(mInput);
    if (r != oboe::Result::OK) {
      ib.setInputPreset(oboe::InputPreset::VoiceRecognition);
      r = ib.openStream(mInput);
    }
    if (r != oboe::Result::OK) {
      mInput.reset();
    } else {
      mInput->requestStart();
    }
  }
  r = mOutput->requestStart();
  if (r != oboe::Result::OK) {
    if (mInput) { mInput->close(); mInput.reset(); }
    mOutput->close();
    mOutput.reset();
    return std::string("não consegui iniciar o áudio (") + oboe::convertToText(r) + ")";
  }
  LOGI("aberto: saída %d Hz rajada %d, entrada %s", mOutput->getSampleRate(), mOutput->getFramesPerBurst(),
       mInput ? "sim" : "não");
  return withInput && !mInput ? "não consegui abrir o microfone" : "";
}

void StudioEngine::close() {
  std::lock_guard<std::mutex> g(mStreamMutex);
  if (mOutput) { mOutput->stop(); mOutput->close(); mOutput.reset(); }
  if (mInput) { mInput->stop(); mInput->close(); mInput.reset(); }
}

void StudioEngine::onErrorAfterClose(oboe::AudioStream*, oboe::Result error) {
  // Fone conectado/desconectado, outro app pegou o áudio…: reabre num thread à parte.
  LOGI("stream caiu (%s), reabrindo", oboe::convertToText(error));
  const bool withInput = mWantInput;
  std::thread([this, withInput] {
    {
      std::lock_guard<std::mutex> g(mStreamMutex);
      if (mInput) { mInput->close(); mInput.reset(); }
      mOutput.reset();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    open(withInput);
  }).detach();
}

std::string StudioEngine::setSong(const std::string& json) {
  std::string err;
  std::shared_ptr<Song> prev;
  {
    std::lock_guard<std::mutex> g(mSongMutex);
    prev = mSong;
  }
  auto song = buildSong(json, prev.get(), kSampleRate, err);
  if (!song) return err;
  std::lock_guard<std::mutex> g(mSongMutex);
  if (mSong) mRetired.push_back(mSong);
  // Mantém só as duas últimas aposentadas (a thread de áudio já trocou há muito tempo).
  while (mRetired.size() > 2) mRetired.erase(mRetired.begin());
  mSong = song;
  mSongDirty = true;
  return err;
}

std::shared_ptr<Song> StudioEngine::currentSong() {
  std::lock_guard<std::mutex> g(mSongMutex);
  return mSong;
}

void StudioEngine::setTrackMix(int64_t id, float volume, float pan, bool mute, bool solo, bool fxOn) {
  auto s = currentSong();
  if (!s) return;
  for (auto& t : s->tracks)
    if (t->id == id) {
      t->volume = volume; t->pan = pan; t->mute = mute; t->solo = solo; t->fxOn = fxOn;
    }
}

void StudioEngine::setTrackFx(int64_t id, const std::string& json) {
  auto s = currentSong();
  if (!s) return;
  FxParams p = parseFx(json);
  for (auto& t : s->tracks)
    if (t->id == id) {
      t->fx.setParams(p);
      t->hasFx = !p.isNeutral();
    }
}

void StudioEngine::setMonitor(bool on, const std::string& fxJson) {
  FxParams p = parseFx(fxJson);
  mMonitorFx.setParams(p);
  mMonitorHasFx = !p.isNeutral();
  if (on && !mMonitorOn) mMonitorFx.reset();
  mMonitorOn = on;
}

void StudioEngine::setInputGainDB(float db) { mInputGain = std::pow(10.0f, std::clamp(db, -24.0f, 24.0f) / 20.0f); }

void StudioEngine::setClick(double bpm, int bpb, bool clickOn) {
  mBpm = std::max(20.0, bpm);
  mBpb = std::max(1, bpb);
  mClickOn = clickOn;
}

std::string StudioEngine::start(int64_t fromFrame, int64_t leadIn, const std::string& recordPath, int64_t silenced) {
  stop();
  if (!mOutput) return "o áudio do Estúdio não está aberto";
  mRecordedFrames = 0;
  mWrittenFrames = 0;
  if (!recordPath.empty()) {
    if (!mInput) return "sem microfone";
    mRecordFile = fopen(recordPath.c_str(), "wb");
    if (!mRecordFile) return "não consegui criar o arquivo da gravação";
    mRing.clear();
    mWriterRun = true;
    mWriter = std::thread([this] { writerLoop(); });
    mCountInEnd = fromFrame;
  } else {
    mCountInEnd = INT64_MIN;
  }
  mClickPos = 1 << 30;
  mSilenced = recordPath.empty() ? -1 : silenced;
  mRecordStart = fromFrame;
  mSongFrame = fromFrame - leadIn;
  mRecording = !recordPath.empty();
  mState = recordPath.empty() ? Playing : (leadIn > 0 ? CountIn : Recording);
  return "";
}

int64_t StudioEngine::stop() {
  const bool wasRecording = mRecording.exchange(false);
  mState = Stopped;
  mSilenced = -1;
  if (mWriter.joinable()) {
    mWriterRun = false;
    mWriter.join();
  }
  if (mRecordFile) {
    fclose(mRecordFile);
    mRecordFile = nullptr;
  }
  return wasRecording ? mWrittenFrames.load() : 0;
}

void StudioEngine::writerLoop() {
  std::vector<float> buf(4096);
  std::vector<int16_t> out(8192);
  auto drain = [&]() {
    size_t n;
    while ((n = mRing.read(buf.data(), buf.size())) > 0) {
      for (size_t i = 0; i < n; i++) {
        const float v = std::clamp(buf[i], -1.0f, 1.0f);
        const int16_t s = int16_t(std::lrint(v * 32767.0f));
        out[2 * i] = s;
        out[2 * i + 1] = s;
      }
      fwrite(out.data(), sizeof(int16_t), n * 2, mRecordFile);
      mWrittenFrames += int64_t(n);
    }
  };
  while (mWriterRun) {
    drain();
    std::this_thread::sleep_for(std::chrono::milliseconds(15));
  }
  drain();
  fflush(mRecordFile);
}

float StudioEngine::takeInputPeak() { return mInputPeak.exchange(0); }

std::vector<float> StudioEngine::trackPeaks() {
  std::vector<float> v;
  auto s = currentSong();
  if (!s) return v;
  for (auto& t : s->tracks) v.push_back(t->peak.exchange(0));
  return v;
}

double StudioEngine::latencyMillis() {
  std::lock_guard<std::mutex> g(mStreamMutex);
  double total = 0;
  if (mOutput) {
    auto r = mOutput->calculateLatencyMillis();
    total += r ? r.value() : 1000.0 * mOutput->getBufferSizeInFrames() / kSampleRate + 10;
  }
  if (mInput) {
    auto r = mInput->calculateLatencyMillis();
    total += r ? r.value() : 1000.0 * mInput->getFramesPerBurst() * 2 / kSampleRate + 10;
  }
  return total;
}

std::string StudioEngine::inputDeviceInfo() {
  std::lock_guard<std::mutex> g(mStreamMutex);
  if (!mInput) return "";
  return std::to_string(mInput->getDeviceId());
}

void StudioEngine::renderClick(float* l, float* r, int n, int64_t songFrame) {
  const double spb = kSampleRate * 60.0 / mBpm.load();
  const int bpb = mBpb.load();
  const bool clickOn = mClickOn.load();
  const int64_t countInEnd = mCountInEnd.load();
  const int clickLen = int(kSampleRate * 0.035);
  for (int i = 0; i < n; i++) {
    const int64_t f = songFrame + i;
    // Batida da grade da música (a mesma do iOS): f cai exatamente numa batida?
    const double beatPos = f / spb;
    const int64_t beatIdx = int64_t(std::floor(beatPos));
    if (int64_t(std::llround(beatIdx * spb)) == f) {
      const bool inCountIn = f < countInEnd;
      if (clickOn || inCountIn) {
        const int inBar = int(((beatIdx % bpb) + bpb) % bpb);
        mClickFreq = inBar == 0 ? 2000.0f : 1100.0f;
        mClickAmp = inBar == 0 ? 0.9f : 0.55f;
        mClickPos = 0;
      }
    }
    if (mClickPos < clickLen) {
      const float t = float(mClickPos) / kSampleRate;
      const float v = std::sin(2.0f * 3.14159265f * mClickFreq * t) * std::exp(-t * 140.0f) * mClickAmp * 0.6f;
      l[i] += v;
      r[i] += v;
      mClickPos++;
    }
  }
}

oboe::DataCallbackResult StudioEngine::onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) {
  float* out = static_cast<float*>(audioData);
  // Disposição nova? Pega sem esperar (se a UI estiver no meio da troca, fica para o próximo bloco).
  if (mSongDirty.load(std::memory_order_acquire)) {
    std::unique_lock<std::mutex> g(mSongMutex, std::try_to_lock);
    if (g.owns_lock()) {
      mSongForAudio = mSong;
      mSongDirty = false;
    }
  }
  int done = 0;
  while (done < numFrames) {
    const int n = std::min(numFrames - done, kMaxBlock);
    // Entrada (sem bloquear): o que não chegou vira silêncio.
    int got = 0;
    if (mInput) {
      auto res = mInput->read(mIn.data(), n, 0);
      if (res) got = res.value();
    }
    std::fill(mIn.begin() + got, mIn.begin() + n, 0.0f);
    const float gain = mInputGain.load(std::memory_order_relaxed);
    float pk = mInputPeak.load(std::memory_order_relaxed);
    for (int i = 0; i < n; i++) {
      mIn[i] *= gain;
      pk = std::max(pk, std::fabs(mIn[i]));
    }
    mInputPeak.store(pk, std::memory_order_relaxed);

    const int st = mState.load(std::memory_order_acquire);
    const int64_t sf = mSongFrame.load(std::memory_order_relaxed);
    if (st != Stopped && mSongForAudio) {
      mMixer.render(*mSongForAudio, sf, n, mL.data(), mR.data(), mSilenced.load(std::memory_order_relaxed));
    } else {
      std::fill(mL.begin(), mL.begin() + n, 0.0f);
      std::fill(mR.begin(), mR.begin() + n, 0.0f);
    }
    if (st != Stopped) renderClick(mL.data(), mR.data(), n, sf);

    // Gravação: só a partir do ponto de entrada (depois da contagem).
    if (st != Stopped && mRecording.load(std::memory_order_relaxed)) {
      const int64_t rs = mRecordStart.load(std::memory_order_relaxed);
      const int64_t from = std::max<int64_t>(0, rs - sf);
      if (from < n) {
        mRing.write(mIn.data() + from, size_t(n - from));
        mRecordedFrames.fetch_add(n - from, std::memory_order_relaxed);
        if (st == CountIn) mState.store(Recording, std::memory_order_release);
      }
    }

    // Retorno ao vivo (com efeitos): use fone para não microfonar.
    if (mMonitorOn.load(std::memory_order_relaxed) && mInput) {
      std::copy(mIn.begin(), mIn.begin() + n, mML.begin());
      std::copy(mIn.begin(), mIn.begin() + n, mMR.begin());
      if (mMonitorHasFx.load(std::memory_order_relaxed)) mMonitorFx.process(mML.data(), mMR.data(), n);
      for (int i = 0; i < n; i++) { mL[i] += mML[i]; mR[i] += mMR[i]; }
    }

    for (int i = 0; i < n; i++) {
      out[2 * (done + i)] = std::clamp(mL[i], -1.0f, 1.0f);
      out[2 * (done + i) + 1] = std::clamp(mR[i], -1.0f, 1.0f);
    }
    if (st != Stopped) mSongFrame.fetch_add(n, std::memory_order_relaxed);
    done += n;
  }
  return oboe::DataCallbackResult::Continue;
}

std::string renderOffline(const std::string& songJson, const std::string& outPath, int64_t totalFrames) {
  std::string err;
  auto song = buildSong(songJson, nullptr, kSampleRate, err);
  if (!song) return err;
  FILE* f = fopen(outPath.c_str(), "wb");
  if (!f) return "não consegui criar o arquivo da exportação";
  Mixer mixer;
  std::vector<float> l(kMaxBlock), r(kMaxBlock);
  std::vector<int16_t> out(kMaxBlock * 2);
  for (int64_t pos = 0; pos < totalFrames; pos += kMaxBlock) {
    const int n = int(std::min<int64_t>(kMaxBlock, totalFrames - pos));
    mixer.render(*song, pos, n, l.data(), r.data(), -1);
    for (int i = 0; i < n; i++) {
      out[2 * i] = int16_t(std::lrint(std::clamp(l[i], -1.0f, 1.0f) * 32767.0f));
      out[2 * i + 1] = int16_t(std::lrint(std::clamp(r[i], -1.0f, 1.0f) * 32767.0f));
    }
    fwrite(out.data(), sizeof(int16_t), size_t(n) * 2, f);
  }
  fclose(f);
  return "";
}

}  // namespace pestana

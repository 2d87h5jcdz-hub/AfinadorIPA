#include "LooperCore.h"

#include <algorithm>
#include <cmath>
#include <new>

namespace pestana {

namespace {
inline int64_t wrap(int64_t a, int64_t n) {
  const int64_t r = a % n;
  return r < 0 ? r + n : r;
}
inline float clampf(float v, float lo, float hi) { return std::min(hi, std::max(lo, v)); }
} // namespace

LooperCore::LooperCore() {
  for (int t = 0; t < kMaxTracks; t++) {
    mTrackLen[t].store(0);
    mTrackAnchor[t].store(0);
    mTrackHasLayer[t].store(false);
    mTrackBusy[t].store(false);
    mTrackPeak[t].store(0.0f);
    mTrackVolume[t].store(1.0f);
  }
}

LooperCore::~LooperCore() {
  // Áudio parado: libera o que a thread de áudio ainda segura, o que está na fila e o devolvido.
  for (auto& tr : mAudio) {
    delete[] tr.main.data;
    delete[] tr.layer.data;
    delete[] tr.rec.data;
  }
  int head = mQueueHead.load();
  const int tail = mQueueTail.load();
  while (head != tail) {
    const Command& c = mQueue[head];
    if (c.type == CmdStartRecord || c.type == CmdSwapMain) delete[] c.buffer.data;
    head = (head + 1) % kQueueSize;
  }
  collectGarbage();
}

// ---------------------------------------------------------------- filas

bool LooperCore::push(const Command& c) {
  const int tail = mQueueTail.load(std::memory_order_relaxed);
  const int next = (tail + 1) % kQueueSize;
  if (next == mQueueHead.load(std::memory_order_acquire)) return false;
  mQueue[tail] = c;
  mQueueTail.store(next, std::memory_order_release);
  return true;
}

void LooperCore::retire(float* p) {
  if (p == nullptr) return;
  const int tail = mRetireTail.load(std::memory_order_relaxed);
  const int next = (tail + 1) % kRetireSize;
  if (next == mRetireHead.load(std::memory_order_acquire)) return;  // cheia: vaza (não deve acontecer)
  mRetire[tail] = p;
  mRetireTail.store(next, std::memory_order_release);
}

void LooperCore::retire(const Buffer& b) { retire(b.data); }

void LooperCore::collectGarbage() {
  int head = mRetireHead.load(std::memory_order_relaxed);
  const int tail = mRetireTail.load(std::memory_order_acquire);
  while (head != tail) {
    delete[] mRetire[head];
    mRetire[head] = nullptr;
    head = (head + 1) % kRetireSize;
  }
  mRetireHead.store(head, std::memory_order_release);
}

LooperCore::Buffer LooperCore::allocate(int64_t frames) {
  Buffer b;
  if (frames <= 0) return b;
  b.data = new (std::nothrow) float[static_cast<size_t>(frames) * kChannels]();
  b.capacity = b.data ? frames : 0;
  return b;
}

// ---------------------------------------------------------------- configuração

void LooperCore::prepare(double sampleRate, double maxBaseSeconds) {
  for (auto& tr : mAudio) {
    delete[] tr.main.data;
    delete[] tr.layer.data;
    delete[] tr.rec.data;
    tr = AudioTrack();
  }
  int head = mQueueHead.load();
  while (head != mQueueTail.load()) {
    const Command& c = mQueue[head];
    if (c.type == CmdStartRecord || c.type == CmdSwapMain) delete[] c.buffer.data;
    head = (head + 1) % kQueueSize;
  }
  mQueueHead.store(0);
  mQueueTail.store(0);
  collectGarbage();
  for (auto& m : mMain) {
    const int mult = m.multiplier;
    m = MainTrack();
    m.multiplier = mult;
  }
  mSampleRate = sampleRate > 0 ? sampleRate : 48000.0;
  mMaxBase = static_cast<int64_t>(mSampleRate * std::max(2.0, maxBaseSeconds));
  mBaseTrack = -1;
  mG = 0;
  mPlayingAudio = false;
  mBaseLen.store(0);
  mPosition.store(0);
  mPlaying.store(false);
  for (int t = 0; t < kMaxTracks; t++) {
    mTrackLen[t].store(0);
    mTrackAnchor[t].store(0);
    mTrackHasLayer[t].store(false);
    mTrackBusy[t].store(false);
    mTrackPeak[t].store(0.0f);
  }
}

void LooperCore::setLatencySamples(int samples) {
  // Lido pela thread de áudio só quando uma gravação para ou escreve; um int64 alinhado basta.
  mLatency = std::max(0, std::min(samples, static_cast<int>(mSampleRate)));
}

void LooperCore::setTrackVolume(int track, float volume) {
  if (track < 0 || track >= kMaxTracks) return;
  mTrackVolume[track].store(clampf(volume, 0.0f, 2.0f));
}

void LooperCore::setTrackMultiplier(int track, int multiplier) {
  if (track < 0 || track >= kMaxTracks) return;
  if (mMain[track].state != Empty) return;
  mMain[track].multiplier = (multiplier == 2 || multiplier == 4) ? multiplier : 1;
}

int LooperCore::trackMultiplier(int track) const {
  if (track < 0 || track >= kMaxTracks) return 1;
  return mMain[track].multiplier;
}

// ---------------------------------------------------------------- ações (principal)

bool LooperCore::anyContent() const {
  for (const auto& m : mMain) if (m.state != Empty) return true;
  return false;
}

bool LooperCore::startRecordingMain(int t) {
  MainTrack& m = mMain[t];
  const bool wasEmpty = m.state == Empty;
  bool othersHaveContent = false;
  for (int i = 0; i < kMaxTracks; i++) if (i != t && mMain[i].state != Empty) othersHaveContent = true;

  if (wasEmpty && !othersHaveContent) {
    // Primeira gravação: define o ciclo.
    Buffer b = allocate(mMaxBase);
    if (!b.data) return false;
    Command c{CmdStartRecord, t, b, 0, false};
    if (!push(c)) { delete[] b.data; return false; }
    m.rec = b;
    m.state = Recording;
    m.muted = false;
    mBaseTrack = t;
    return true;
  }

  const int64_t base = mBaseLen.load();
  if (base <= 0) return false;                    // a thread de áudio ainda não fechou o ciclo
  if (mTrackBusy[t].load()) return false;         // ainda escrevendo a cauda da gravação anterior

  if (m.layer.data) {
    if (!mergeLayerMain(t)) return false;
  }
  const int64_t length = wasEmpty ? base * m.multiplier : mTrackLen[t].load();
  if (length <= 0) return false;
  Buffer b = allocate(length);
  if (!b.data) return false;
  if (!mPlaying.load()) push(Command{CmdPlay, t, {}, 0, false});
  if (m.muted) {
    push(Command{CmdMute, t, {}, 0, false});
    m.muted = false;
  }
  Command c{CmdStartRecord, t, b, length, false};
  if (!push(c)) { delete[] b.data; return false; }
  m.rec = b;
  m.state = wasEmpty ? Recording : Overdubbing;
  return true;
}

void LooperCore::stopRecordingMain(int t) {
  MainTrack& m = mMain[t];
  if (m.state != Recording && m.state != Overdubbing) return;
  push(Command{CmdStopRecord, t, {}, 0, false});
  // Ao fim da cauda a thread de áudio faz a mesma troca: rec vira main (1ª gravação) ou layer.
  if (!m.main.data) m.main = m.rec;
  else m.layer = m.rec;
  m.rec = Buffer();
  m.state = Playing;
  if (mBaseTrack == t) mBaseTrack = -1;
}

bool LooperCore::mergeLayerMain(int t) {
  MainTrack& m = mMain[t];
  const int64_t length = mTrackLen[t].load();
  if (length <= 0 || !m.main.data || !m.layer.data) return false;
  Buffer merged = allocate(length);
  if (!merged.data) return false;
  for (int c = 0; c < kChannels; c++) {
    const float* a = m.main.ch(c);
    const float* b = m.layer.ch(c);
    float* o = merged.ch(c);
    for (int64_t i = 0; i < length; i++) o[i] = a[i] + b[i];
  }
  if (!push(Command{CmdSwapMain, t, merged, length, false})) {
    delete[] merged.data;
    return false;
  }
  m.main = merged;     // os antigos são devolvidos pela thread de áudio
  m.layer = Buffer();
  return true;
}

bool LooperCore::press(int track) {
  if (track < 0 || track >= kMaxTracks) return false;
  // Gravando o ciclo base: qualquer botão fecha o ciclo (como numa pedaleira).
  if (mBaseTrack >= 0) {
    stopRecordingMain(mBaseTrack);
    return true;
  }
  MainTrack& m = mMain[track];
  switch (m.state) {
    case Empty:
      return startRecordingMain(track);
    case Recording:
    case Overdubbing:
      stopRecordingMain(track);
      return true;
    case Playing:
      if (!mPlaying.load()) {        // tudo parado: o botão volta a tocar
        playAll();
        if (m.muted) toggleMute(track);
        return true;
      }
      if (m.muted) {                 // faixa parada: volta a tocar
        toggleMute(track);
        return true;
      }
      return startRecordingMain(track);
  }
  return false;
}

void LooperCore::toggleMute(int track) {
  if (track < 0 || track >= kMaxTracks) return;
  MainTrack& m = mMain[track];
  if (m.state == Empty) return;
  if (m.state == Recording || m.state == Overdubbing) stopRecordingMain(track);
  m.muted = !m.muted;
  push(Command{CmdMute, track, {}, 0, m.muted});
}

void LooperCore::undo(int track) {
  if (track < 0 || track >= kMaxTracks) return;
  MainTrack& m = mMain[track];
  if (m.state == Recording || m.state == Overdubbing || mTrackBusy[track].load()) return;
  if (m.layer.data) {
    push(Command{CmdDropLayer, track, {}, 0, false});
    m.layer = Buffer();
  } else if (m.state != Empty) {
    clearTrack(track);
  }
}

void LooperCore::clearTrack(int track) {
  if (track < 0 || track >= kMaxTracks) return;
  MainTrack& m = mMain[track];
  if (m.state == Empty) return;
  push(Command{CmdClearTrack, track, {}, 0, false});
  const int mult = m.multiplier;
  m = MainTrack();
  m.multiplier = mult;
  if (mBaseTrack == track) mBaseTrack = -1;
}

void LooperCore::stopAll() {
  for (int t = 0; t < kMaxTracks; t++) stopRecordingMain(t);
  push(Command{CmdStop, 0, {}, 0, false});
}

void LooperCore::playAll() {
  if (!anyContent()) return;
  push(Command{CmdPlay, 0, {}, 0, false});
}

void LooperCore::clearAll() {
  push(Command{CmdClearAll, 0, {}, 0, false});
  for (auto& m : mMain) {
    const int mult = m.multiplier;
    m = MainTrack();
    m.multiplier = mult;
  }
  mBaseTrack = -1;
}

// ---------------------------------------------------------------- leitura (principal)

LooperCore::TrackState LooperCore::trackState(int track) const {
  if (track < 0 || track >= kMaxTracks) return Empty;
  return mMain[track].state;
}

bool LooperCore::trackMuted(int track) const {
  if (track < 0 || track >= kMaxTracks) return false;
  return mMain[track].muted;
}

bool LooperCore::trackCanUndo(int track) const {
  if (track < 0 || track >= kMaxTracks) return false;
  const MainTrack& m = mMain[track];
  return m.state == Playing && !mTrackBusy[track].load();
}

float LooperCore::trackProgress(int track) const {
  if (track < 0 || track >= kMaxTracks) return 0.0f;
  const int64_t len = mTrackLen[track].load();
  if (len <= 0) return 0.0f;
  return static_cast<float>(wrap(mPosition.load() - mTrackAnchor[track].load(), len)) / static_cast<float>(len);
}

float LooperCore::trackLevel(int track) const {
  if (track < 0 || track >= kMaxTracks) return 0.0f;
  return mTrackPeak[track].load();
}

int64_t LooperCore::trackLength(int track) const {
  if (track < 0 || track >= kMaxTracks) return 0;
  return mTrackLen[track].load();
}

// ---------------------------------------------------------------- thread de áudio

void LooperCore::finishRecording(int t) {
  AudioTrack& tr = mAudio[t];
  tr.recording = false;
  tr.tail = 0;
  if (tr.rec.data) {
    if (!tr.main.data) {
      tr.main = tr.rec;
    } else if (!tr.layer.data) {
      tr.layer = tr.rec;
      mTrackHasLayer[t].store(true);
    } else {
      // Não deveria acontecer (a principal junta antes de sobregravar): soma na camada.
      for (int c = 0; c < kChannels; c++) {
        float* d = tr.layer.ch(c);
        const float* s = tr.rec.ch(c);
        for (int64_t i = 0; i < tr.length; i++) d[i] += s[i];
      }
      retire(tr.rec);
    }
  }
  tr.rec = Buffer();
  mTrackBusy[t].store(false);
}

void LooperCore::applyCommand(const Command& c) {
  const int t = c.track;
  switch (c.type) {
    case CmdStartRecord: {
      AudioTrack& tr = mAudio[t];
      if (tr.recording || tr.tail > 0) finishRecording(t);
      if (c.length == 0) {
        // Ciclo base: tudo recomeça do zero.
        retire(tr.main); retire(tr.layer); retire(tr.rec);
        tr = AudioTrack();
        tr.isBase = true;
        tr.rec = c.buffer;
        tr.recording = true;
        mG = 0;
        mPlayingAudio = true;
        mBaseLen.store(0);
        mTrackLen[t].store(0);
        mTrackAnchor[t].store(0);
        mTrackHasLayer[t].store(false);
      } else {
        const int64_t base = mBaseLen.load();
        if (tr.length == 0) {
          tr.length = c.length;
          // Faixas de 2 ou 4 ciclos começam no início do ciclo em que a gravação começou.
          tr.anchor = (c.length > base && base > 0) ? (mG / base) * base : 0;
          mTrackLen[t].store(tr.length);
          mTrackAnchor[t].store(tr.anchor);
        }
        tr.rec = c.buffer;
        tr.recording = true;
      }
      mTrackBusy[t].store(true);
      break;
    }
    case CmdStopRecord: {
      AudioTrack& tr = mAudio[t];
      if (!tr.recording) break;
      tr.recording = false;
      if (tr.isBase) {
        int64_t base = std::min(mG, tr.rec.capacity);
        tr.isBase = false;
        if (base < static_cast<int64_t>(mSampleRate * 0.1)) {
          // Toque duplo sem querer: descarta.
          retire(tr.rec);
          tr = AudioTrack();
          mTrackBusy[t].store(false);
          mPlayingAudio = false;
          mG = 0;
          break;
        }
        tr.length = base;
        tr.anchor = 0;
        if (mG >= base) mG = mG % base;
        mBaseLen.store(base);
        mTrackLen[t].store(base);
        mTrackAnchor[t].store(0);
      }
      tr.tail = mLatency;
      if (tr.tail <= 0) finishRecording(t);
      break;
    }
    case CmdSwapMain: {
      AudioTrack& tr = mAudio[t];
      retire(tr.main);
      retire(tr.layer);
      tr.main = c.buffer;
      tr.layer = Buffer();
      mTrackHasLayer[t].store(false);
      break;
    }
    case CmdDropLayer: {
      AudioTrack& tr = mAudio[t];
      retire(tr.layer);
      tr.layer = Buffer();
      mTrackHasLayer[t].store(false);
      break;
    }
    case CmdClearTrack: {
      AudioTrack& tr = mAudio[t];
      retire(tr.main); retire(tr.layer); retire(tr.rec);
      tr = AudioTrack();
      mTrackLen[t].store(0);
      mTrackAnchor[t].store(0);
      mTrackHasLayer[t].store(false);
      mTrackBusy[t].store(false);
      mTrackPeak[t].store(0.0f);
      bool any = false;
      for (const auto& o : mAudio) if (o.length > 0 || o.recording || o.isBase) any = true;
      if (!any) {
        mBaseLen.store(0);
        mPlayingAudio = false;
        mG = 0;
      }
      break;
    }
    case CmdClearAll: {
      for (int i = 0; i < kMaxTracks; i++) {
        AudioTrack& tr = mAudio[i];
        retire(tr.main); retire(tr.layer); retire(tr.rec);
        tr = AudioTrack();
        mTrackLen[i].store(0);
        mTrackAnchor[i].store(0);
        mTrackHasLayer[i].store(false);
        mTrackBusy[i].store(false);
        mTrackPeak[i].store(0.0f);
      }
      mBaseLen.store(0);
      mPlayingAudio = false;
      mG = 0;
      break;
    }
    case CmdPlay:
      if (mBaseLen.load() > 0) {
        mG = 0;
        mPlayingAudio = true;
      }
      break;
    case CmdStop:
      for (int i = 0; i < kMaxTracks; i++) {
        AudioTrack& tr = mAudio[i];
        if (tr.recording || tr.tail > 0) finishRecording(i);
      }
      mPlayingAudio = false;
      mG = 0;
      break;
    case CmdMute:
      mAudio[t].muted = c.flag;
      break;
  }
}

void LooperCore::process(const float* const* in, float* const* out, int frames) {
  // Comandos da principal.
  int head = mQueueHead.load(std::memory_order_relaxed);
  const int tail = mQueueTail.load(std::memory_order_acquire);
  while (head != tail) {
    applyCommand(mQueue[head]);
    head = (head + 1) % kQueueSize;
  }
  mQueueHead.store(head, std::memory_order_release);

  const bool monitor = mMonitor.load();
  const int64_t latency = mLatency;
  float volume[kMaxTracks];
  float peak[kMaxTracks];
  for (int t = 0; t < kMaxTracks; t++) {
    volume[t] = mTrackVolume[t].load();
    peak[t] = 0.0f;
  }
  float inPeak = 0.0f;

  for (int i = 0; i < frames; i++) {
    const float x0 = in[0][i];
    const float x1 = in[1][i];
    inPeak = std::max(inPeak, std::max(std::fabs(x0), std::fabs(x1)));
    float y0 = monitor ? x0 : 0.0f;
    float y1 = monitor ? x1 : 0.0f;

    if (mPlayingAudio) {
      for (int t = 0; t < kMaxTracks; t++) {
        AudioTrack& tr = mAudio[t];
        // Leitura
        if (tr.length > 0 && !tr.muted) {
          const int64_t idx = wrap(mG - tr.anchor, tr.length);
          float s0 = 0.0f, s1 = 0.0f;
          if (tr.main.data) { s0 += tr.main.ch(0)[idx]; s1 += tr.main.ch(1)[idx]; }
          if (tr.layer.data) { s0 += tr.layer.ch(0)[idx]; s1 += tr.layer.ch(1)[idx]; }
          if (tr.rec.data) { s0 += tr.rec.ch(0)[idx]; s1 += tr.rec.ch(1)[idx]; }
          s0 *= volume[t];
          s1 *= volume[t];
          y0 += s0;
          y1 += s1;
          peak[t] = std::max(peak[t], std::max(std::fabs(s0), std::fabs(s1)));
        }
        // Escrita (com compensação de latência)
        if ((tr.recording || tr.tail > 0) && tr.rec.data) {
          if (tr.isBase) {
            const int64_t w = mG - latency;
            if (w >= 0 && w < tr.rec.capacity) {
              tr.rec.ch(0)[w] += x0;
              tr.rec.ch(1)[w] += x1;
            }
          } else if (tr.length > 0) {
            const int64_t w = wrap(mG - latency - tr.anchor, tr.length);
            tr.rec.ch(0)[w] += x0;
            tr.rec.ch(1)[w] += x1;
          }
          if (!tr.recording && --tr.tail <= 0) finishRecording(t);
        }
      }
      mG++;
    }
    out[0][i] = clampf(y0, -1.0f, 1.0f);
    out[1][i] = clampf(y1, -1.0f, 1.0f);
  }

  mPosition.store(mG);
  mPlaying.store(mPlayingAudio);
  // Pico com queda (~300 ms com blocos de 5 ms).
  for (int t = 0; t < kMaxTracks; t++) {
    const float old = mTrackPeak[t].load(std::memory_order_relaxed);
    mTrackPeak[t].store(std::max(peak[t], old * 0.85f), std::memory_order_relaxed);
  }
  const float oldIn = mInputPeak.load(std::memory_order_relaxed);
  mInputPeak.store(std::max(inPeak, oldIn * 0.85f), std::memory_order_relaxed);
}

} // namespace pestana

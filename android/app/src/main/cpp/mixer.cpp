#include "mixer.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>

#include "nlohmann/json.hpp"

namespace pestana {

std::shared_ptr<MappedPcm> MappedPcm::open(const std::string& path) {
  int fd = ::open(path.c_str(), O_RDONLY);
  if (fd < 0) return nullptr;
  struct stat st {};
  if (fstat(fd, &st) != 0 || st.st_size < 4) {
    ::close(fd);
    return nullptr;
  }
  void* base = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
  ::close(fd);
  if (base == MAP_FAILED) return nullptr;
  madvise(base, size_t(st.st_size), MADV_WILLNEED);
  auto p = std::shared_ptr<MappedPcm>(new MappedPcm());
  p->mBase = base;
  p->mSize = size_t(st.st_size);
  p->data = static_cast<const int16_t*>(base);
  p->frames = int64_t(st.st_size / 4);
  return p;
}

MappedPcm::~MappedPcm() {
  if (mBase) munmap(mBase, mSize);
}

TrackState::TrackState(int64_t i) : id(i) {}

void Mixer::render(const Song& song, int64_t songFrame, int n, float* outL, float* outR, int64_t silenced) {
  std::fill(outL, outL + n, 0.0f);
  std::fill(outR, outR + n, 0.0f);
  bool anySolo = false;
  for (auto& t : song.tracks) anySolo |= t->solo.load(std::memory_order_relaxed);

  for (auto& tp : song.tracks) {
    TrackState& t = *tp;
    const bool audible = !t.mute.load(std::memory_order_relaxed) && !(anySolo && !t.solo.load(std::memory_order_relaxed)) &&
                         t.id != silenced;
    std::fill(mL, mL + n, 0.0f);
    std::fill(mR, mR + n, 0.0f);
    bool any = false;
    if (audible) {
      for (const ClipRef& c : t.clips) {
        const int64_t a = std::max(songFrame, c.offset);
        const int64_t b = std::min(songFrame + n, c.offset + c.duration);
        if (a >= b || !c.pcm) continue;
        any = true;
        for (int64_t f = a; f < b; f++) {
          const int64_t src = c.fileStart + (f - c.offset);
          if (src < 0 || src >= c.pcm->frames) continue;
          const int i = int(f - songFrame);
          mL[i] = c.pcm->data[src * 2] * (1.0f / 32768.0f);
          mR[i] = c.pcm->data[src * 2 + 1] * (1.0f / 32768.0f);
        }
      }
    }
    // A cadeia roda mesmo sem clip no trecho para o rabo do reverb/delay continuar soando.
    if (audible && t.hasFx.load(std::memory_order_relaxed) && t.fxOn.load(std::memory_order_relaxed)) {
      t.fx.process(mL, mR, n);
      any = true;
    }
    if (!any) {
      t.peak.store(t.peak.load(std::memory_order_relaxed) * 0.9f, std::memory_order_relaxed);
      continue;
    }
    const float vol = t.volume.load(std::memory_order_relaxed);
    const float pan = std::clamp(t.pan.load(std::memory_order_relaxed), -1.0f, 1.0f);
    const float angle = (pan + 1) * 0.25f * 3.14159265f;  // pan de potência constante
    const float gl = vol * std::cos(angle) * 1.41421356f, gr = vol * std::sin(angle) * 1.41421356f;
    float pk = 0;
    for (int i = 0; i < n; i++) {
      const float l = mL[i] * gl, r = mR[i] * gr;
      outL[i] += l;
      outR[i] += r;
      pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
    }
    t.peak.store(std::max(pk, t.peak.load(std::memory_order_relaxed) * 0.9f), std::memory_order_relaxed);
  }
}

FxParams parseFx(const std::string& text) {
  FxParams p;
  auto j = nlohmann::json::parse(text, nullptr, false);
  if (j.is_discarded() || !j.is_object()) return p;
  auto f = [&](const char* k, float& v) { if (j.contains(k) && j[k].is_number()) v = j[k].get<float>(); };
  auto b = [&](const char* k, bool& v) { if (j.contains(k) && j[k].is_boolean()) v = j[k].get<bool>(); };
  auto i = [&](const char* k, int& v) { if (j.contains(k) && j[k].is_number()) v = j[k].get<int>(); };
  b("gateEnabled", p.gateEnabled);
  f("gateThresholdDB", p.gateThresholdDB);
  f("eqLowDB", p.eqLowDB); f("eqMidDB", p.eqMidDB); f("eqHighDB", p.eqHighDB);
  b("compressorEnabled", p.compressorEnabled);
  f("compressorAmount", p.compressorAmount);
  f("driveAmount", p.driveAmount);
  i("driveStyle", p.driveStyle);
  f("delayMix", p.delayMix); f("delayTime", p.delayTime); f("delayFeedback", p.delayFeedback);
  f("reverbMix", p.reverbMix);
  if (j.contains("ampPath") && j["ampPath"].is_string()) p.ampModel = j["ampPath"].get<std::string>();
  f("ampInputDB", p.ampInputDB); f("ampOutputDB", p.ampOutputDB);
  i("modType", p.modType);
  f("modRate", p.modRate); f("modDepth", p.modDepth); f("modMix", p.modMix);
  return p;
}

std::shared_ptr<Song> buildSong(const std::string& text, const Song* previous, double sampleRate, std::string& error) {
  auto song = std::make_shared<Song>();
  auto j = nlohmann::json::parse(text, nullptr, false);
  if (j.is_discarded() || !j.is_object() || !j.contains("tracks")) {
    error = "disposição inválida";
    return nullptr;
  }
  // Mapeamentos de arquivo reaproveitados da disposição anterior (não remapeia à toa).
  std::map<std::string, std::shared_ptr<MappedPcm>> files;
  if (previous)
    for (auto& t : previous->tracks)
      for (auto& c : t->clips)
        if (c.pcm) files[c.path] = c.pcm;
  for (auto& jt : j["tracks"]) {
    auto t = std::make_shared<TrackState>(jt.value("id", int64_t(0)));
    t->fx.prepare(sampleRate, kMaxBlock);
    t->volume = jt.value("volume", 1.0f);
    t->pan = jt.value("pan", 0.0f);
    t->mute = jt.value("mute", false);
    t->solo = jt.value("solo", false);
    t->fxOn = jt.value("fxOn", true);
    if (jt.contains("clips")) {
      for (auto& jc : jt["clips"]) {
        const std::string path = jc.value("path", std::string());
        std::shared_ptr<MappedPcm> pcm;
        auto fit = files.find(path);
        if (fit != files.end() && fit->second) {
          pcm = fit->second;
        } else {
          pcm = MappedPcm::open(path);
          files[path] = pcm;
        }
        if (!pcm) {
          error = "arquivo de áudio ausente: " + path;
          continue;
        }
        ClipRef c;
        c.pcm = pcm;
        c.path = path;
        c.offset = jc.value("offset", int64_t(0));
        c.fileStart = jc.value("fileStart", int64_t(0));
        c.duration = jc.value("duration", int64_t(0));
        t->clips.push_back(c);
      }
    }
    if (jt.contains("fx")) {
      FxParams p = parseFx(jt["fx"].dump());
      t->hasFx = !p.isNeutral();
      t->fx.setParams(p);
    }
    song->tracks.push_back(t);
  }
  return song;
}

}  // namespace pestana

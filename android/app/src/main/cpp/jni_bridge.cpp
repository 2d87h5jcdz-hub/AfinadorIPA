// Ponte JNI: com.pestana.estudio.studio.NativeStudio ↔ pestana::StudioEngine.
#include <jni.h>

#include <string>

#include "studio_engine.h"

using pestana::StudioEngine;

namespace {
std::string str(JNIEnv* env, jstring s) {
  if (!s) return {};
  const char* c = env->GetStringUTFChars(s, nullptr);
  std::string out(c);
  env->ReleaseStringUTFChars(s, c);
  return out;
}
jstring jstr(JNIEnv* env, const std::string& s) { return s.empty() ? nullptr : env->NewStringUTF(s.c_str()); }
StudioEngine* E(jlong h) { return reinterpret_cast<StudioEngine*>(h); }
}  // namespace

#define FN(name) Java_com_pestana_estudio_studio_NativeStudio_##name

extern "C" {

JNIEXPORT jlong JNICALL FN(nCreate)(JNIEnv*, jobject) { return reinterpret_cast<jlong>(new StudioEngine()); }
JNIEXPORT void JNICALL FN(nDestroy)(JNIEnv*, jobject, jlong h) { delete E(h); }
JNIEXPORT jstring JNICALL FN(nOpen)(JNIEnv* env, jobject, jlong h, jboolean in, jint device) {
  return jstr(env, E(h)->open(in, device));
}
JNIEXPORT void JNICALL FN(nClose)(JNIEnv*, jobject, jlong h) { E(h)->close(); }
JNIEXPORT jboolean JNICALL FN(nHasInput)(JNIEnv*, jobject, jlong h) { return E(h)->hasInput(); }
JNIEXPORT jstring JNICALL FN(nSetSong)(JNIEnv* env, jobject, jlong h, jstring json) {
  return jstr(env, E(h)->setSong(str(env, json)));
}
JNIEXPORT void JNICALL FN(nSetTrackMix)(JNIEnv*, jobject, jlong h, jlong id, jfloat vol, jfloat pan, jboolean mute,
                                        jboolean solo, jboolean fxOn) {
  E(h)->setTrackMix(id, vol, pan, mute, solo, fxOn);
}
JNIEXPORT void JNICALL FN(nSetTrackFx)(JNIEnv* env, jobject, jlong h, jlong id, jstring json) {
  E(h)->setTrackFx(id, str(env, json));
}
JNIEXPORT void JNICALL FN(nSetMonitor)(JNIEnv* env, jobject, jlong h, jboolean on, jstring json) {
  E(h)->setMonitor(on, str(env, json));
}
JNIEXPORT void JNICALL FN(nSetInputGain)(JNIEnv*, jobject, jlong h, jfloat db) { E(h)->setInputGainDB(db); }
JNIEXPORT void JNICALL FN(nSetClick)(JNIEnv*, jobject, jlong h, jdouble bpm, jint bpb, jboolean on) {
  E(h)->setClick(bpm, bpb, on);
}
JNIEXPORT jstring JNICALL FN(nStart)(JNIEnv* env, jobject, jlong h, jlong from, jlong lead, jstring path, jlong silenced) {
  return jstr(env, E(h)->start(from, lead, str(env, path), silenced));
}
JNIEXPORT jlong JNICALL FN(nStop)(JNIEnv*, jobject, jlong h) { return E(h)->stop(); }
JNIEXPORT jlongArray JNICALL FN(nStatus)(JNIEnv* env, jobject, jlong h) {
  jlong v[3] = {E(h)->state(), E(h)->songFrame(), E(h)->recordedFrames()};
  jlongArray a = env->NewLongArray(3);
  env->SetLongArrayRegion(a, 0, 3, v);
  return a;
}
JNIEXPORT jfloatArray JNICALL FN(nLevels)(JNIEnv* env, jobject, jlong h) {
  auto peaks = E(h)->trackPeaks();
  jfloatArray a = env->NewFloatArray(jsize(peaks.size() + 1));
  float in = E(h)->takeInputPeak();
  env->SetFloatArrayRegion(a, 0, 1, &in);
  if (!peaks.empty()) env->SetFloatArrayRegion(a, 1, jsize(peaks.size()), peaks.data());
  return a;
}
JNIEXPORT jdouble JNICALL FN(nLatencyMs)(JNIEnv*, jobject, jlong h) { return E(h)->latencyMillis(); }
JNIEXPORT jstring JNICALL FN(nRenderOffline)(JNIEnv* env, jobject, jstring json, jstring out, jlong frames) {
  return jstr(env, pestana::renderOffline(str(env, json), str(env, out), frames));
}
}

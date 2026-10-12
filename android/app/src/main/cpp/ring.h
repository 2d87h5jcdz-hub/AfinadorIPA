#pragma once
#include <atomic>
#include <cstddef>
#include <vector>

namespace pestana {

/// Fila circular sem trava, um produtor (thread de áudio) e um consumidor (gravador em disco).
class FloatRing {
 public:
  explicit FloatRing(size_t capacity) : mBuf(capacity) {}
  size_t write(const float* src, size_t n) {
    const size_t w = mWrite.load(std::memory_order_relaxed), r = mRead.load(std::memory_order_acquire);
    const size_t free = mBuf.size() - (w - r);
    const size_t k = n < free ? n : free;
    for (size_t i = 0; i < k; i++) mBuf[(w + i) % mBuf.size()] = src[i];
    mWrite.store(w + k, std::memory_order_release);
    if (k < n) mOverflow.fetch_add(n - k, std::memory_order_relaxed);
    return k;
  }
  size_t read(float* dst, size_t n) {
    const size_t r = mRead.load(std::memory_order_relaxed), w = mWrite.load(std::memory_order_acquire);
    const size_t avail = w - r;
    const size_t k = n < avail ? n : avail;
    for (size_t i = 0; i < k; i++) dst[i] = mBuf[(r + i) % mBuf.size()];
    mRead.store(r + k, std::memory_order_release);
    return k;
  }
  void clear() { mRead.store(mWrite.load()); mOverflow = 0; }
  size_t overflow() const { return mOverflow.load(); }
 private:
  std::vector<float> mBuf;
  std::atomic<size_t> mWrite{0}, mRead{0}, mOverflow{0};
};

}  // namespace pestana

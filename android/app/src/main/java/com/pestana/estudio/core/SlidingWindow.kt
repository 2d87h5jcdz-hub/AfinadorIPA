package com.pestana.estudio.core

/**
 * Junta os blocos do microfone (de qualquer tamanho) em janelas de [window] amostras que
 * avançam de [hop] em [hop] — o afinador analisa 4096 amostras a cada 1024.
 */
class SlidingWindow(private val window: Int, private val hop: Int) {
    private val ring = FloatArray(window * 2)
    private var filled = 0
    private val frame = FloatArray(window)

    fun reset() {
        filled = 0
    }

    /** Chama [onFrame] para cada janela completa (o array é reaproveitado entre chamadas). */
    inline fun feed(block: FloatArray, n: Int, onFrame: (FloatArray) -> Unit) {
        var off = 0
        while (off < n) {
            off += push(block, off, n - off)
            while (ready()) onFrame(next())
        }
    }

    @PublishedApi
    internal fun push(block: FloatArray, off: Int, count: Int): Int {
        val take = minOf(count, ring.size - filled)
        System.arraycopy(block, off, ring, filled, take)
        filled += take
        return take
    }

    @PublishedApi
    internal fun ready(): Boolean = filled >= window

    @PublishedApi
    internal fun next(): FloatArray {
        System.arraycopy(ring, 0, frame, 0, window)
        System.arraycopy(ring, hop, ring, 0, filled - hop)
        filled -= hop
        return frame
    }
}

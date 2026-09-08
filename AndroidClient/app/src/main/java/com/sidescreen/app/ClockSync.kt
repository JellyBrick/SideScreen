package com.sidescreen.app

/**
 * NTP-style host↔client clock offset estimation from v2 pong timestamps.
 *
 * For each exchange: t0 = client send, t1 = host receive, t2 = host send,
 * t3 = client receive (all monotonic nanos on their own clocks).
 *   rtt    = (t3 - t0) - (t2 - t1)
 *   offset = ((t1 - t0) + (t2 - t3)) / 2      // hostNs ≈ clientNs + offset
 *
 * The offset of the LOWEST-rtt sample in a sliding window is used (min
 * filter): queueing delay only ever inflates rtt, so the smallest sample is
 * the least contaminated one. Accuracy is bounded by path asymmetry — under
 * one-directional video load that is roughly rtt/2, which the chunked v2
 * framing keeps small.
 */
class ClockSync {
    private data class Sample(val rttNs: Long, val offsetNs: Long)

    private val samples = ArrayDeque<Sample>()
    private val lock = Any()

    @Volatile
    var offsetNs: Long = 0
        private set

    @Volatile
    var minRttNs: Long = 0
        private set

    @Volatile
    var isValid: Boolean = false
        private set

    fun reset() {
        synchronized(lock) {
            samples.clear()
            offsetNs = 0
            minRttNs = 0
            isValid = false
        }
    }

    /** Returns the exchange's rtt in nanoseconds. */
    fun onPong(
        t0: Long,
        t1: Long,
        t2: Long,
        t3: Long,
    ): Long {
        val rtt = (t3 - t0) - (t2 - t1)
        val offset = ((t1 - t0) + (t2 - t3)) / 2
        if (rtt < 0) return rtt
        synchronized(lock) {
            samples.addLast(Sample(rtt, offset))
            while (samples.size > WINDOW) {
                samples.removeFirst()
            }
            val best = samples.minByOrNull { it.rttNs } ?: return rtt
            offsetNs = best.offsetNs
            minRttNs = best.rttNs
            isValid = true
        }
        return rtt
    }

    /** Convert a host monotonic timestamp into this device's clock. */
    fun hostToClientNs(hostNs: Long): Long = hostNs - offsetNs

    companion object {
        private const val WINDOW = 64
    }
}

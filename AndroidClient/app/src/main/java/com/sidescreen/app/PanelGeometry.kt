package com.sidescreen.app

import android.content.Context
import android.hardware.display.DisplayManager
import android.view.Display

/** Native panel size in landscape orientation, plus the fastest mode it can present. */
data class PanelGeometry(
    val width: Int,
    val height: Int,
    val refreshHz: Int,
) {
    companion object {
        /**
         * [Display.Mode.physicalWidth] and [Display.Mode.physicalHeight] report the panel in its
         * natural orientation whatever the current rotation, so this answer is stable when the
         * tablet is turned. Null when the display or its mode is unavailable.
         */
        fun of(display: Display?): PanelGeometry? {
            val mode = display?.mode ?: return null
            val w = maxOf(mode.physicalWidth, mode.physicalHeight)
            val h = minOf(mode.physicalWidth, mode.physicalHeight)
            if (w <= 0 || h <= 0) return null
            // Peak rate over all modes, not the current one: a panel parked at 60 can still be
            // asked for 90, and decoding faster than the peak only burns throughput budget.
            val hz =
                display.supportedModes
                    ?.maxOfOrNull { it.refreshRate }
                    ?.toInt()
                    ?: display.refreshRate.toInt()
            return PanelGeometry(w, h, hz.coerceIn(24, 240))
        }

        fun ofDefaultDisplay(context: Context): PanelGeometry? =
            try {
                val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                of(dm.getDisplay(Display.DEFAULT_DISPLAY))
            } catch (_: Exception) {
                null
            }
    }
}

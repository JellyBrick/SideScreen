package com.sidescreen.app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.content.ContextCompat

/**
 * USB accessory (AOA) lifecycle: attach intents, the permission dialog, and
 * detach cleanup. The Mac switches the tablet into accessory mode; this side
 * only ever opens the accessory the Mac announced (manufacturer/model match
 * via accessory_filter.xml).
 */
class AccessoryConnectionManager(
    private val activity: Activity,
    /** An accessory is present and permitted — try connecting via AOA. */
    private val onAccessoryReady: () -> Unit,
    /** The cable/mode went away; any open descriptor is already closed. */
    private val onAccessoryDetached: () -> Unit,
) {
    private val usbManager = activity.getSystemService(Context.USB_SERVICE) as UsbManager
    private var openDescriptor: ParcelFileDescriptor? = null
    private var permissionRequested = false

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                when (intent.action) {
                    ACTION_USB_PERMISSION -> {
                        permissionRequested = false
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        if (granted) {
                            onAccessoryReady()
                        } else {
                            DiagLog.log("AOA", "USB permission denied by user")
                        }
                    }

                    UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                        closeActive()
                        onAccessoryDetached()
                    }
                }
            }
        }

    init {
        val filter =
            IntentFilter().apply {
                addAction(ACTION_USB_PERMISSION)
                addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            }
        ContextCompat.registerReceiver(activity, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** ATTACHED intents arrive via onCreate/onNewIntent (launchMode singleTask). */
    fun handleIntent(intent: Intent?): Boolean {
        if (intent?.action != UsbManager.ACTION_USB_ACCESSORY_ATTACHED) return false
        DiagLog.log("AOA", "Accessory attached intent")
        onAccessoryReady()
        return true
    }

    private fun matchingAccessory(): UsbAccessory? =
        usbManager.accessoryList?.firstOrNull {
            it.manufacturer == EXPECTED_MANUFACTURER && it.model == EXPECTED_MODEL
        }

    /** The Mac has already switched us into accessory mode and is waiting. */
    fun hasAccessory(): Boolean = matchingAccessory() != null

    /**
     * Opens the accessory when present and permitted. When permission is
     * missing, asks for it (once) and returns null — the permission grant
     * fires [onAccessoryReady] and the caller retries.
     */
    fun openIfAvailable(): ParcelFileDescriptor? {
        val accessory = matchingAccessory() ?: return null
        if (!usbManager.hasPermission(accessory)) {
            requestPermission(accessory)
            return null
        }
        closeActive()
        val descriptor = usbManager.openAccessory(accessory)
        if (descriptor == null) {
            DiagLog.log("AOA", "openAccessory failed")
            return null
        }
        openDescriptor = descriptor
        return descriptor
    }

    private fun requestPermission(accessory: UsbAccessory) {
        if (permissionRequested) return
        permissionRequested = true
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Must be MUTABLE: the system appends the grant-result extras.
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        val pi =
            PendingIntent.getBroadcast(
                activity,
                0,
                Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName),
                flags,
            )
        DiagLog.log("AOA", "Requesting USB accessory permission")
        usbManager.requestPermission(accessory, pi)
    }

    fun closeActive() {
        try {
            openDescriptor?.close()
        } catch (_: Exception) {
        }
        openDescriptor = null
    }

    fun release() {
        closeActive()
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.sidescreen.app.USB_PERMISSION"

        // Mirror of MacHost/Sources/AOA/AOAUSB.swift AOAConstants.
        private const val EXPECTED_MANUFACTURER = "SideScreen"
        private const val EXPECTED_MODEL = "SideScreen"
    }
}

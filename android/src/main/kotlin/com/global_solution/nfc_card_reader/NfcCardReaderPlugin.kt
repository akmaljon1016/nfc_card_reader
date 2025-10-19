package com.global_solution.nfc_card_reader

import android.app.Activity
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.IOException

class NfcCardReaderPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, NfcAdapter.ReaderCallback {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    // Synchronize access to eventSink
    private val eventSinkLock = Any()
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var nfcAdapter: NfcAdapter? = null
    private var isReading = false

    private val TAG = "NfcCardReaderPlugin"

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onAttachedToEngine called")

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "nfc_card_reader")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "nfc_card_reader/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                synchronized(eventSinkLock) {
                    Log.d(TAG, "EventChannel onListen called - listener registered")
                    eventSink = events
                }
            }

            override fun onCancel(arguments: Any?) {
                synchronized(eventSinkLock) {
                    Log.d(TAG, "EventChannel onCancel called - listener removed")
                    eventSink = null
                }
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")

        when (call.method) {
            "isNfcAvailable" -> {
                val available = nfcAdapter != null
                Log.d(TAG, "isNfcAvailable: $available")
                result.success(available)
            }
            "isNfcEnabled" -> {
                val enabled = nfcAdapter?.isEnabled == true
                Log.d(TAG, "isNfcEnabled: $enabled")
                result.success(enabled)
            }
            "startReading" -> {
                Log.d(TAG, "startReading called")
                startReading()
                result.success(null)
            }
            "stopReading" -> {
                Log.d(TAG, "stopReading called")
                stopReading()
                result.success(null)
            }
            "openNfcSettings" -> {
                Log.d(TAG, "openNfcSettings called")
                openNfcSettings()
                result.success(null)
            }
            else -> {
                Log.d(TAG, "Method not implemented: ${call.method}")
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onDetachedFromEngine called")
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        Log.d(TAG, "onAttachedToActivity called")
        activity = binding.activity
        nfcAdapter = NfcAdapter.getDefaultAdapter(activity)
        Log.d(TAG, "NfcAdapter initialized: ${nfcAdapter != null}")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        Log.d(TAG, "onDetachedFromActivityForConfigChanges called")
        stopReading()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        Log.d(TAG, "onReattachedToActivityForConfigChanges called")
        activity = binding.activity
        if (isReading) {
            startReading()
        }
    }

    override fun onDetachedFromActivity() {
        Log.d(TAG, "onDetachedFromActivity called")
        stopReading()
        activity = null
    }

    private fun startReading() {
        val currentActivity = activity
        if (currentActivity == null) {
            Log.e(TAG, "Cannot start reading: activity is null")
            sendError("Activity not available")
            return
        }

        val adapter = nfcAdapter
        if (adapter == null) {
            Log.e(TAG, "Cannot start reading: NFC adapter is null")
            sendError("NFC not available on this device")
            return
        }

        if (!adapter.isEnabled) {
            Log.e(TAG, "Cannot start reading: NFC is disabled")
            sendError("NFC is disabled. Please enable it in settings")
            return
        }

        synchronized(eventSinkLock) {
            if (eventSink == null) {
                Log.w(TAG, "Warning: Starting NFC reading but no event listener is registered")
            }
        }

        isReading = true

        val options = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250)
        }

        adapter.enableReaderMode(
            currentActivity,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                    NfcAdapter.FLAG_READER_NFC_B or
                    NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            options
        )

        Log.d(TAG, "NFC reader mode enabled successfully")
    }

    private fun stopReading() {
        val adapter = nfcAdapter
        val currentActivity = activity

        if (adapter != null && currentActivity != null) {
            adapter.disableReaderMode(currentActivity)
            Log.d(TAG, "NFC reader mode disabled")
        } else {
            Log.w(TAG, "Cannot disable reader mode: adapter or activity is null")
        }

        isReading = false
    }

    override fun onTagDiscovered(tag: Tag?) {
        if (tag == null) {
            Log.e(TAG, "onTagDiscovered called with null tag")
            return
        }

        val tagId = tag.id.joinToString("") { "%02X".format(it) }
        Log.d(TAG, "Tag discovered: $tagId")

        synchronized(eventSinkLock) {
            Log.d(TAG, "EventSink is null: ${eventSink == null}")
        }

        val isoDep = IsoDep.get(tag)
        if (isoDep == null) {
            Log.e(TAG, "Card doesn't support IsoDep")
            sendError("Card doesn't support IsoDep")
            return
        }

        try {
            Log.d(TAG, "Connecting to IsoDep...")
            isoDep.connect()
            isoDep.timeout = 5000
            Log.d(TAG, "IsoDep connected successfully")

            Log.d(TAG, "Starting card data read...")
            val reader = EmvCardReader(isoDep)
            val cardData = reader.readCardData()

            if (cardData != null) {
                Log.d(TAG, "Card data read successfully")
                Log.d(TAG, "Card Number: ${cardData.cardNumber}")
                Log.d(TAG, "Expiration: ${cardData.expirationDate}")
                Log.d(TAG, "Cardholder: ${cardData.cardholderName ?: "N/A"}")
                sendCardData(cardData)
            } else {
                Log.e(TAG, "Could not read card data - readCardData returned null")
                sendError("Could not read card data")
            }
        } catch (e: IOException) {
            Log.e(TAG, "IO Error reading card: ${e.message}", e)
            sendError("IO Error: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "Error reading card: ${e.message}", e)
            e.printStackTrace()
            sendError("Error: ${e.message}")
        } finally {
            try {
                if (isoDep.isConnected) {
                    isoDep.close()
                    Log.d(TAG, "IsoDep connection closed")
                }
            } catch (e: IOException) {
                Log.e(TAG, "Error closing IsoDep: ${e.message}")
            }
        }
    }

    private fun sendCardData(cardData: CardData) {
        Log.d(TAG, "sendCardData called")
        Log.d(TAG, "Card Number: ${cardData.cardNumber}")
        Log.d(TAG, "Expiration: ${cardData.expirationDate}")
        Log.d(TAG, "Cardholder: ${cardData.cardholderName ?: "null"}")

        val data = mapOf(
            "type" to "card",
            "data" to mapOf(
                "cardNumber" to cardData.cardNumber,
                "expirationDate" to cardData.expirationDate,
                "cardholderName" to cardData.cardholderName
            )
        )

        activity?.runOnUiThread {
            synchronized(eventSinkLock) {
                if (eventSink != null) {
                    try {
                        eventSink?.success(data)
                        Log.d(TAG, "Card data sent to Flutter successfully")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error sending card data to Flutter: ${e.message}", e)
                    }
                } else {
                    Log.e(TAG, "EventSink is null, cannot send card data to Flutter")
                }
            }
        }
    }

    private fun sendError(message: String) {
        Log.e(TAG, "sendError called: $message")

        val data = mapOf(
            "type" to "error",
            "message" to message
        )

        activity?.runOnUiThread {
            synchronized(eventSinkLock) {
                if (eventSink != null) {
                    try {
                        eventSink?.success(data)
                        Log.d(TAG, "Error sent to Flutter successfully")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error sending error message to Flutter: ${e.message}", e)
                    }
                } else {
                    Log.e(TAG, "EventSink is null, cannot send error to Flutter")
                }
            }
        }
    }

    private fun openNfcSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Intent(Settings.Panel.ACTION_NFC)
        } else {
            Intent(Settings.ACTION_NFC_SETTINGS)
        }
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        activity?.startActivity(intent)
        Log.d(TAG, "NFC settings opened")
    }
}

data class CardData(
    val cardNumber: String,
    val expirationDate: String,
    val cardholderName: String? = null
)
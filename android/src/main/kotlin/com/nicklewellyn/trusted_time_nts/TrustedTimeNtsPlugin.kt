package com.nicklewellyn.trusted_time_nts

import android.content.Context
import android.os.SystemClock
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.TimeUnit

/** Main entry point for the TrustedTime Android plugin. */
class TrustedTimeNtsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var backgroundChannel: MethodChannel
    private lateinit var integrityChannel: EventChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "trusted_time_nts/monotonic")
        methodChannel.setMethodCallHandler(this)

        backgroundChannel = MethodChannel(binding.binaryMessenger, "trusted_time_nts/background")
        backgroundChannel.setMethodCallHandler(this)

        integrityChannel = EventChannel(binding.binaryMessenger, "trusted_time_nts/integrity")
        integrityChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) =
                IntegrityWatcher.attach(context, sink)
            override fun onCancel(args: Any?) = IntegrityWatcher.detach(context)
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getUptimeMs" -> result.success(SystemClock.elapsedRealtime())
            "enableBackgroundSync" -> {
                val hours = call.argument<Int>("intervalHours") ?: 24
                scheduleBackgroundSync(hours.toLong())
                result.success(null)
            }
            "setBackgroundCallbackHandle" -> {
                val handle = call.argument<Number>("handle")?.toLong()
                if (handle == null) {
                    result.error("INVALID_ARGS", "handle is required", null)
                    return
                }
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putLong(KEY_HANDLE, handle)
                    .apply()
                result.success(null)
            }
            "notifyBackgroundComplete" -> {
                // The worker installs its own scoped handler on the headless
                // engine's binary messenger after Dart starts (see
                // [BackgroundSyncWorker.runHeadlessSync]); that handler is
                // what actually unblocks the worker. This branch only fires
                // on the foreground engine, where the call is a no-op so a
                // foreground TrustedTime.runBackgroundSync() invocation
                // cannot prematurely complete an in-flight background run.
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun scheduleBackgroundSync(intervalHours: Long) {
        val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(intervalHours, TimeUnit.HOURS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork("trusted_time_nts_sync", ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        backgroundChannel.setMethodCallHandler(null)
        IntegrityWatcher.detach(context)
    }

    companion object {
        internal const val PREFS = "trusted_time_nts_prefs"
        internal const val KEY_HANDLE = "tt_bg_callback_handle"
        internal const val BG_CHANNEL = "trusted_time_nts/background"
    }
}

/**
 * Periodic worker that performs the actual anchor refresh.
 *
 * If the host app has registered a Dart callback via
 * `TrustedTime.registerBackgroundCallback`, this worker spins up a headless
 * [FlutterEngine], invokes that callback (which is expected to call
 * `TrustedTime.runBackgroundSync()`), and waits for completion via the
 * `trusted_time_nts/background.notifyBackgroundComplete` method-channel call.
 *
 * If no callback is registered, this falls back to a connectivity-only
 * HTTPS HEAD probe, preserving the pre-2.x behaviour for integrators that
 * have not yet adopted the host-registered callback pattern.
 */
class BackgroundSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(
            TrustedTimeNtsPlugin.PREFS, Context.MODE_PRIVATE,
        )
        val handle = prefs.getLong(TrustedTimeNtsPlugin.KEY_HANDLE, 0L)
        if (handle == 0L) return runConnectivityFallback()

        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(handle)
            ?: return runConnectivityFallback()

        return runHeadlessSync(callbackInfo)
    }

    private suspend fun runHeadlessSync(
        callbackInfo: FlutterCallbackInformation,
    ): Result {
        val deferred = CompletableDeferred<Boolean>()
        // FlutterEngine creation, plugin/channel wiring, and
        // executeDartCallback must run on the main thread; once Dart is
        // running the awaited completion arrives via a channel callback
        // (also delivered on main) but the suspended wait itself runs on
        // the worker's default dispatcher to avoid pinning a 9-minute
        // budget to Main and contending with the host app's UI work.
        val (engine, workerChannel) = withContext(Dispatchers.Main) {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)
            // Install the completion handler directly on the headless
            // engine's binary messenger so a foreground engine running in
            // the same process cannot complete this worker's deferred
            // (each FlutterEngine has its own messenger).
            val workerChannel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                TrustedTimeNtsPlugin.BG_CHANNEL,
            )
            workerChannel.setMethodCallHandler { call, result ->
                if (call.method == "notifyBackgroundComplete") {
                    val success = call.argument<Boolean>("success") ?: false
                    // CompletableDeferred.complete returns false (rather than
                    // throwing) when the deferred has already been resolved,
                    // which makes duplicate notifyBackgroundComplete calls or
                    // a late call racing with teardown safe. We discard the
                    // boolean intentionally — only the first signal counts.
                    deferred.complete(success)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
            val args = DartExecutor.DartCallback(
                applicationContext.assets,
                loader.findAppBundlePath(),
                callbackInfo,
            )
            engine.dartExecutor.executeDartCallback(args)
            engine to workerChannel
        }

        return try {
            // 9-minute budget leaves headroom inside WorkManager's
            // 10-minute default cap; tasks that exceed this are killed by
            // the OS. The wait runs off-main on the worker's coroutine
            // dispatcher (Dispatchers.Default by default for
            // CoroutineWorker), so a long Dart sync does not block Main.
            val success = withTimeoutOrNull(9 * 60 * 1000L) { deferred.await() }
            if (success == true) Result.success() else Result.retry()
        } finally {
            // Teardown must hop back to Main and complete even if the
            // worker is cancelled (e.g., WorkManager kills the run on the
            // 10-minute boundary), otherwise the FlutterEngine leaks.
            withContext(NonCancellable + Dispatchers.Main) {
                workerChannel.setMethodCallHandler(null)
                engine.destroy()
            }
        }
    }

    private fun runConnectivityFallback(): Result = try {
        val url = java.net.URL("https://www.google.com")
        val conn = url.openConnection() as java.net.HttpURLConnection
        conn.requestMethod = "HEAD"
        conn.connectTimeout = 5000
        conn.readTimeout = 5000
        conn.connect()
        // HttpURLConnection.connect() does not throw on non-2xx responses,
        // so a captive portal returning 302/403 would otherwise be reported
        // as a success and suppress WorkManager's backoff. Gate on the 2xx
        // range to match the iOS performConnectivityFallback semantics.
        val code = conn.responseCode
        conn.disconnect()
        if (code in 200..299) Result.success() else Result.retry()
    } catch (_: Exception) {
        Result.retry()
    }
}

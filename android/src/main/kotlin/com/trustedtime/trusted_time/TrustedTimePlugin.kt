package com.trustedtime.trusted_time

import android.content.Context
import android.os.SystemClock
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.TimeUnit

/** Main entry point for the TrustedTime Android plugin. */
class TrustedTimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var backgroundChannel: MethodChannel
    private lateinit var integrityChannel: EventChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "trusted_time/monotonic")
        methodChannel.setMethodCallHandler(this)

        backgroundChannel = MethodChannel(binding.binaryMessenger, "trusted_time/background")
        backgroundChannel.setMethodCallHandler(this)

        integrityChannel = EventChannel(binding.binaryMessenger, "trusted_time/integrity")
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
            .enqueueUniquePeriodicWork("trusted_time_sync", ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        backgroundChannel.setMethodCallHandler(null)
        IntegrityWatcher.detach(context)
    }

    companion object {
        internal const val PREFS = "trusted_time_prefs"
        internal const val KEY_HANDLE = "tt_bg_callback_handle"
        internal const val BG_CHANNEL = "trusted_time/background"
    }
}

/**
 * Periodic worker that performs the actual anchor refresh.
 *
 * If the host app has registered a Dart callback via
 * `TrustedTime.registerBackgroundCallback`, this worker spins up a headless
 * [FlutterEngine], invokes that callback (which is expected to call
 * `TrustedTime.runBackgroundSync()`), and waits for completion via the
 * `trusted_time/background.notifyBackgroundComplete` method-channel call.
 *
 * If no callback is registered, this falls back to a connectivity-only
 * HTTPS HEAD probe, preserving the previous behaviour for integrators that
 * have not yet adopted the host-registered callback pattern.
 */
class BackgroundSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(
            TrustedTimePlugin.PREFS, Context.MODE_PRIVATE,
        )
        val handle = prefs.getLong(TrustedTimePlugin.KEY_HANDLE, 0L)
        if (handle == 0L) return runConnectivityFallback()

        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(handle)
            ?: return runConnectivityFallback()

        return runHeadlessSync(callbackInfo)
    }

    private suspend fun runHeadlessSync(
        callbackInfo: FlutterCallbackInformation,
    ): Result {
        val deferred = CompletableDeferred<Boolean>()
        // Captured outside the try so the finally can tear down whatever
        // was created even when initialization itself throws partway
        // (e.g. executeDartCallback failing after the engine exists).
        var engine: FlutterEngine? = null
        var workerChannel: MethodChannel? = null

        return try {
            // FlutterEngine creation, plugin/channel wiring, and
            // executeDartCallback must run on the main thread; once Dart is
            // running the awaited completion arrives via a channel callback
            // (also delivered on main) but the suspended wait itself runs on
            // the worker's default dispatcher to avoid pinning a 9-minute
            // budget to Main and contending with the host app's UI work.
            withContext(Dispatchers.Main) {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)

                // The FlutterEngine constructor auto-registers the host
                // app's GeneratedPluginRegistrant onto this headless engine
                // (v2 embedding), so plugin channels — this plugin's
                // trusted_time/monotonic and flutter_secure_storage for
                // anchor persistence — are live before Dart starts.
                val headless = FlutterEngine(applicationContext)
                engine = headless
                // Install the completion handler directly on the headless
                // engine's binary messenger so a foreground engine running in
                // the same process cannot complete this worker's deferred
                // (each FlutterEngine has its own messenger). Setting this
                // handler after engine construction also replaces the one
                // installed by auto-registration for the same channel name.
                val channel = MethodChannel(
                    headless.dartExecutor.binaryMessenger,
                    TrustedTimePlugin.BG_CHANNEL,
                )
                workerChannel = channel
                channel.setMethodCallHandler { call, result ->
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
                headless.dartExecutor.executeDartCallback(args)
            }

            // 9-minute budget leaves headroom inside WorkManager's
            // 10-minute default cap; tasks that exceed this are killed by
            // the OS. The wait runs off-main on the worker's coroutine
            // dispatcher (Dispatchers.Default by default for
            // CoroutineWorker), so a long Dart sync does not block Main.
            val success = withTimeoutOrNull(9 * 60 * 1000L) { deferred.await() }
            if (success == true) Result.success() else Result.retry()
        } catch (e: CancellationException) {
            // Preserve cooperative cancellation: WorkManager cancelling
            // the worker must propagate, not be converted into a retry.
            // The finally below still tears the engine down (its
            // withContext is NonCancellable).
            throw e
        } catch (_: Exception) {
            // Loader/engine/callback initialization failures land here.
            // Ask WorkManager to retry with backoff rather than letting
            // the exception escape doWork (which would record a permanent
            // Result.failure() for this iteration).
            Result.retry()
        } finally {
            // Teardown must hop back to Main and complete even if the
            // worker is cancelled (e.g., WorkManager kills the run on the
            // 10-minute boundary) or initialization threw partway,
            // otherwise the FlutterEngine leaks.
            withContext(NonCancellable + Dispatchers.Main) {
                workerChannel?.setMethodCallHandler(null)
                engine?.destroy()
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

package com.ajiputra.fake_gps

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

/**
 * External keep-alive for ROMs that freeze backgrounded processes.
 *
 * The service's own tick is a `Handler.postDelayed` on a `HandlerThread`. That is
 * sufficient on stock Android, where a foreground service is never suspended. On
 * ColorOS (and similar OEM skins) `ColorHansManager` moves the whole *process* into a
 * frozen cgroup once the UI is backgrounded — timers stop, threads stop, no wake lock
 * helps, because the process is not scheduled at all. Observed directly on CPH1911:
 *
 *     I/ColorHansManager: pkg: com.ajiputra.telemetrykit, state: R -> F
 *     I/ColorHansManager: freeze uid: 10596 reason: F-direct scene: LcdOnScene
 *
 * An exact alarm is delivered by `AlarmManagerService` in the system_server process,
 * which is not frozen. It unfreezes the target, runs [onReceive], and [MockLocationService]
 * re-arms the tick and re-pushes to every provider — closing the gap before any client
 * declares the fix stream dead and falls back to the real GPS.
 *
 * **Measured limitation, not a guess.** `setExactAndAllowWhileIdle` is throttled by
 * `AlarmManagerService` to roughly one delivery per 60 s per uid once the device is idle,
 * so this receiver alone produces a *bursty* stream — enough to keep `dumpsys location`
 * showing a fresh fix, not enough for a 2 Hz client. It is therefore a backup, not the
 * primary defence: the primary defence is the Doze whitelist written by
 * `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, which keeps the Handler tick
 * running at full rate and never lets the process be frozen in the first place.
 */
class WatchdogReceiver : BroadcastReceiver() {

    companion object {
        private const val ACTION_TICK = "com.ajiputra.fake_gps.action.WATCHDOG"
        private const val REQUEST_CODE = 8213

        /** Re-armed every second while mocking is supposed to be live. */
        private const val PERIOD_MS = 1_000L
        /**
         * Arms (or re-arms) the revive alarm. Safe to call from any thread and from a
         * frozen process: `AlarmManager` lives in system_server, so the call itself is
         * not the thing being suspended.
         */
        fun arm(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val pi = pending(context)
            val trigger = SystemClock.elapsedRealtime() + PERIOD_MS
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
                    // Without SCHEDULE_EXACT_ALARM the inexact alarm still fires while
                    // the screen is on and is only batched while idle. It is a strictly
                    // worse keep-alive, not a no-op.
                    am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, pi)
                } else {
                    am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, pi)
                }
            } catch (_: Throwable) {
                try {
                    am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, trigger, pi)
                } catch (_: Throwable) {
                }
            }
        }

        fun disarm(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            try {
                am.cancel(pending(context))
            } catch (_: Throwable) {
            }
        }

        private fun pending(context: Context): PendingIntent {
            val intent = Intent(context, WatchdogReceiver::class.java).setAction(ACTION_TICK)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            // On API 31+ FLAG_MUTABLE is required for S+ exact alarms in some builds;
            // IMMUTABLE is the correct default for an alarm with no extras.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                flags = PendingIntent.FLAG_UPDATE_CURRENT
            }
            return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_TICK) return
        if (!MockLocationService.isRunning) {
            disarm(context)
            return
        }
        // Pulling the process out of the freezer is not enough on its own: the Handler
        // thread resumes with whatever was queued before the freeze, which may be
        // several seconds stale. Force a push now and restart the cadence from zero.
        MockLocationService.requestImmediatePush(context)
        arm(context)
    }
}

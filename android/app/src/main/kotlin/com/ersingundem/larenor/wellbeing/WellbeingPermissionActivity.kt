package com.ersingundem.larenor.wellbeing

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.health.connect.client.PermissionController

/** Not exported. No measurements or profile labels enter activity state. */
class WellbeingPermissionActivity : ComponentActivity() {
    companion object { const val EXTRA_TICKET = "permissionTicket" }
    private var ticket: String? = null
    private val permissionLauncher = registerForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) {
        // Actual current permission state is queried by the originating bridge;
        // the callback never starts any health-data read.
        WellbeingPermissionRuntime.broker.finish(ticket)
        finish()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        ticket = try { intent.getStringExtra(EXTRA_TICKET) } catch (_: RuntimeException) { null }
        val pending = if (savedInstanceState == null) WellbeingPermissionRuntime.broker.take(ticket)
            else WellbeingPermissionRuntime.broker.active(ticket)
        if (pending == null) { finish(); return }
        if (savedInstanceState == null) {
            try { permissionLauncher.launch(pending.metrics.map { it.permission }.toSet()) }
            catch (_: RuntimeException) { WellbeingPermissionRuntime.broker.finish(ticket); finish() }
        }
    }
    override fun onDestroy() {
        if (isFinishing) WellbeingPermissionRuntime.broker.finish(ticket)
        super.onDestroy()
    }
}

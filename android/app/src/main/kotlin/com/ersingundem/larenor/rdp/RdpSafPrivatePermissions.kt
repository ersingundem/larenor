package com.ersingundem.larenor.rdp

import android.system.Os
import java.io.FileDescriptor

internal const val RDP_SAF_PRIVATE_FILE_MODE = 0b110_000_000
internal const val RDP_SAF_PRIVATE_DIRECTORY_MODE = 0b111_000_000

/**
 * The only production boundary for SAF private-storage permission changes.
 *
 * Tests may inject a recorder, but production constructors always default to the real Android
 * syscalls. Failures propagate so callers can preserve their existing fail-closed behavior.
 */
internal fun interface RdpSafDescriptorPermission {
    fun setMode(descriptor: FileDescriptor, mode: Int)
}

internal fun interface RdpSafPathPermission {
    fun setMode(path: String, mode: Int)
}

internal data class RdpSafPrivatePermissions(
    val descriptor: RdpSafDescriptorPermission,
    val path: RdpSafPathPermission,
) {
    companion object {
        val ANDROID = RdpSafPrivatePermissions(
            descriptor = RdpSafDescriptorPermission { descriptor, mode ->
                Os.fchmod(descriptor, mode)
            },
            path = RdpSafPathPermission { path, mode ->
                Os.chmod(path, mode)
            },
        )
    }
}

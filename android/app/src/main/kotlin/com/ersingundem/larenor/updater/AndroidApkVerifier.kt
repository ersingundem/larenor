package com.ersingundem.larenor.updater

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import com.android.apksig.ApkVerifier
import java.io.File
import java.security.MessageDigest

class AndroidApkVerifier(private val context: Context) {
    @Suppress("DEPRECATION")
    private val flags get() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    fun installed(): InstalledClient {
        val info = context.packageManager.getPackageInfo(context.packageName, flags)
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        val certificates = signatures?.map { sha256(it.toByteArray()) }?.toSet().orEmpty()
        if (certificates.isEmpty()) throw UpdateFailure("unavailable")
        return InstalledClient(info.packageName, version(info), info.versionName.orEmpty(), certificates, Build.VERSION.SDK_INT)
    }
    @Suppress("DEPRECATION")
    fun verify(file: File): ArchiveIdentity {
        try {
            val certificates = verifiedApkCertificates(file, Build.VERSION.SDK_INT)
            val info = context.packageManager.getPackageArchiveInfo(file.path, flags) ?: throw UpdateFailure("verification")
            val application = info.applicationInfo ?: throw UpdateFailure("verification")
            if (!info.splitNames.isNullOrEmpty()) throw UpdateFailure("verification")
            return ArchiveIdentity(info.packageName, version(info), info.versionName.orEmpty(), application.minSdkVersion,
                certificates, true)
        } catch (_: Exception) { throw UpdateFailure("verification") }
    }
    fun verifyHash(file: File, release: ClientRelease, cancellation: UpdateCancellation) {
        if (!file.isFile || file.length() != release.sizeBytes) throw UpdateFailure("verification")
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { cancellation.check(); val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        if (digest.digest().joinToString("") { "%02x".format(it) } != release.apkSha256) throw UpdateFailure("verification")
    }
}

internal fun verifiedApkCertificates(file: File, sdkInt: Int): Set<String> {
    try {
        val result = ApkVerifier.Builder(file).setMinCheckedPlatformVersion(26)
            .setMaxCheckedPlatformVersion(sdkInt).build().verify()
        if (!result.isVerified || result.signerCertificates.isEmpty()) throw UpdateFailure("verification")
        return result.signerCertificates.map { sha256(it.encoded) }.toSet()
    } catch (_: Exception) { throw UpdateFailure("verification") }
}

package com.ersingundem.larenor.cast

import android.content.Context
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/**
 * Enables official Cast discovery without claiming playback ownership. The
 * selected device is matched by UUID to Music Assistant and controlled there.
 */
class LarenorCastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder()
        .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
        .setStopReceiverApplicationWhenEndingSession(false)
        .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

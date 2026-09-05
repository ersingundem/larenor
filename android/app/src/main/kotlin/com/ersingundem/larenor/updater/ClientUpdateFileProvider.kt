package com.ersingundem.larenor.updater

import androidx.core.content.FileProvider

/** Dedicated provider required by the AndroidX FileProvider compatibility guidance. */
class ClientUpdateFileProvider : FileProvider()

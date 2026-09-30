package com.ersingundem.larenor.game

import android.app.Activity
import java.lang.reflect.Method
import java.util.function.Consumer

/** Optional packaged engine boundary; ordinary APKs do not link Moonlight classes. */
interface GameStreamEmbeddedHost {
    fun handle(method: String, arguments: Any?, success: Consumer<Any?>, error: Consumer<String>): Boolean
    fun setResumed(value: Boolean)
    fun setWindowFocused(value: Boolean)
    fun dispose()
}

internal object MoonlightEmbeddedHostLoader {
    private const val HOST_CLASS = "com.ersingundem.larenor.game.moonlight.MoonlightMethodChannelHost"

    fun load(activity: Activity): GameStreamEmbeddedHost? = try {
        val type = Class.forName(HOST_CLASS, true, activity.classLoader)
        // Validate the complete lifecycle before constructing an effect-capable runtime.
        val handle = type.getMethod("handle", String::class.java, Any::class.java, Consumer::class.java, Consumer::class.java)
        require(handle.returnType == Boolean::class.javaPrimitiveType)
        val resumed = type.getMethod("setResumed", Boolean::class.javaPrimitiveType)
        val focused = type.getMethod("setWindowFocused", Boolean::class.javaPrimitiveType)
        val dispose = type.getMethod("dispose")
        ReflectiveHost(type.getConstructor(Activity::class.java).newInstance(activity), handle, resumed, focused, dispose)
    } catch (_: ReflectiveOperationException) {
        null
    } catch (_: LinkageError) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    private class ReflectiveHost(
        private val target: Any,
        private val handle: Method,
        private val resumed: Method,
        private val focused: Method,
        private val close: Method,
    ) : GameStreamEmbeddedHost {
        private var active = true

        override fun handle(method: String, arguments: Any?, success: Consumer<Any?>, error: Consumer<String>): Boolean {
            if (!active) {
                error.accept("engine_unavailable")
                return true
            }
            return try {
                handle.invoke(target, method, arguments, success, error) as Boolean
            } catch (_: ReflectiveOperationException) {
                active = false
                runCatching { close.invoke(target) }
                error.accept("engine_unavailable")
                true
            }
        }

        override fun setResumed(value: Boolean) = update(resumed, value)
        override fun setWindowFocused(value: Boolean) = update(focused, value)

        private fun update(method: Method, value: Boolean) {
            if (!active) return
            try {
                method.invoke(target, value)
            } catch (_: ReflectiveOperationException) {
                active = false
                runCatching { close.invoke(target) }
            }
        }

        override fun dispose() {
            active = false
            runCatching { close.invoke(target) }
        }
    }
}

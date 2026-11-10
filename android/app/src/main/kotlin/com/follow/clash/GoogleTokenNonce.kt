package com.follow.clash

import com.google.gson.JsonParser

internal object GoogleTokenNonce {
    fun accountEmail(payload: String): String? = try {
        val email = JsonParser.parseString(payload).asJsonObject.get("email")
        if (email != null && email.isJsonPrimitive && email.asJsonPrimitive.isString) {
            email.asString.takeIf { it.length in 3..320 && it.contains('@') }
        } else null
    } catch (_: RuntimeException) {
        null
    }

    fun matches(payload: String, expected: String): Boolean {
        if (expected.isBlank()) return false
        return try {
            val claims = JsonParser.parseString(payload)
            if (!claims.isJsonObject) return false
            val nonce = claims.asJsonObject.get("nonce")
            nonce != null && nonce.isJsonPrimitive && nonce.asJsonPrimitive.isString &&
                nonce.asString == expected
        } catch (_: RuntimeException) {
            false
        }
    }
}

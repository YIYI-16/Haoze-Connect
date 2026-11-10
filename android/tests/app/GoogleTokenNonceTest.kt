package com.follow.clash

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GoogleTokenNonceTest {
    @Test
    fun `account hint is only used to select the native authorization account`() {
        assertEquals("user@example.com", GoogleTokenNonce.accountEmail("""{"email":"user@example.com"}"""))
        for (payload in listOf("not-json", "[]", "null", "{}", """{"email":123}""", """{"email":""}""", """{"email":false}""")) {
            assertNull(GoogleTokenNonce.accountEmail(payload))
        }
    }

    @Test
    fun `credential must contain the current request nonce`() {
        assertTrue(GoogleTokenNonce.matches("""{"nonce":"current","sub":"subject"}""", "current"))
        assertFalse(GoogleTokenNonce.matches("""{"sub":"subject"}""", "current"))
        assertFalse(GoogleTokenNonce.matches("""{"nonce":"previous"}""", "current"))
    }

    @Test
    fun `malformed or non string nonce cannot pass preflight`() {
        for (payload in listOf("not-json", "[]", "null", "{}", """{"nonce":null}""", """{"nonce":123}""", """{"nonce":true}""", """{"nonce":["current"]}""")) {
            assertFalse(payload, GoogleTokenNonce.matches(payload, "current"))
        }
        assertFalse(GoogleTokenNonce.matches("""{"nonce":""}""", ""))
    }
}

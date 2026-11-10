package com.follow.clash

import android.accounts.Account
import android.app.Activity
import android.content.Intent
import android.util.Base64
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class NativeGoogleLogin(private val activity: Activity, messenger: BinaryMessenger) {
    private class Attempt(val result: MethodChannel.Result, val requestCode: Int) {
        var awaitingResolution = false
    }

    private val channel = MethodChannel(messenger, "haoze/native_google")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pending: Attempt? = null
    private var nextRequestCode = 28000

    init {
        channel.setMethodCallHandler { call, result ->
            when {
                call.method == "cancel" -> {
                    pending?.let { fail(it, "cancelled") }
                    result.success(null)
                }
                call.method != "signIn" -> result.notImplemented()
                pending != null -> result.error("busy", "Google sign-in is already running", null)
                else -> {
                    val clientId = call.argument<String>("serverClientId")
                    val nonce = call.argument<String>("nonce")
                    if (clientId.isNullOrBlank() || nonce.isNullOrBlank() || nextRequestCode > 65535) {
                        result.error("configuration", "Google sign-in is not configured", null)
                    } else {
                        val attempt = Attempt(result, nextRequestCode++)
                        pending = attempt
                        scope.launch { signIn(attempt, clientId, nonce) }
                    }
                }
            }
        }
    }

    private suspend fun signIn(attempt: Attempt, clientId: String, nonce: String) {
        try {
            val option = GetGoogleIdOption.Builder()
                .setServerClientId(clientId)
                .setFilterByAuthorizedAccounts(false)
                .setAutoSelectEnabled(false)
                .setNonce(nonce)
                .build()
            val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
            val credential = CredentialManager.create(activity).getCredential(activity, request).credential
            if (pending !== attempt) return
            if (credential !is CustomCredential || credential.type !in setOf(
                    GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL,
                    GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_SIWG_CREDENTIAL,
                )) {
                fail(attempt, "credential")
                return
            }
            val token = GoogleIdTokenCredential.createFrom(credential.data).idToken
            val payload = token.split('.').getOrNull(1) ?: throw IllegalArgumentException()
            val decoded = String(Base64.decode(payload, Base64.URL_SAFE), Charsets.UTF_8)
            if (GoogleTokenNonce.matches(decoded, nonce)) {
                succeed(attempt, "id_token", token)
            } else {
                val email = GoogleTokenNonce.accountEmail(decoded) ?: throw IllegalArgumentException()
                authorizeCode(attempt, clientId, email)
            }
        } catch (_: GetCredentialCancellationException) {
            fail(attempt, "cancelled")
        } catch (_: CancellationException) {
            fail(attempt, "cancelled")
        } catch (_: Exception) {
            fail(attempt, "unavailable")
        }
    }

    private fun authorizeCode(attempt: Attempt, clientId: String, email: String) {
        val request = AuthorizationRequest.builder()
            .setAccount(Account(email, "com.google"))
            .setRequestedScopes(listOf(Scope("openid"), Scope("email"), Scope("profile")))
            .requestOfflineAccess(clientId)
            .build()
        Identity.getAuthorizationClient(activity).authorize(request)
            .addOnSuccessListener { result ->
                if (pending !== attempt) return@addOnSuccessListener
                try {
                    if (result.hasResolution()) {
                        val intent = result.pendingIntent ?: throw IllegalStateException()
                        attempt.awaitingResolution = true
                        activity.startIntentSenderForResult(intent.intentSender, attempt.requestCode, null, 0, 0, 0)
                    } else {
                        completeCode(attempt, result)
                    }
                } catch (_: Exception) {
                    fail(attempt, "unavailable")
                }
            }
            .addOnFailureListener { error ->
                fail(attempt, if (error is ApiException && error.statusCode == CommonStatusCodes.CANCELED) "cancelled" else "unavailable")
            }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val attempt = pending ?: return false
        if (!attempt.awaitingResolution || requestCode != attempt.requestCode) return false
        if (resultCode != Activity.RESULT_OK) {
            fail(attempt, "cancelled")
        } else {
            try {
                completeCode(attempt, Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data))
            } catch (_: Exception) {
                fail(attempt, "unavailable")
            }
        }
        return true
    }

    private fun completeCode(attempt: Attempt, result: AuthorizationResult) {
        val code = result.serverAuthCode
        if (code.isNullOrBlank()) fail(attempt, "credential") else succeed(attempt, "server_auth_code", code)
    }

    private fun succeed(attempt: Attempt, key: String, value: String) {
        if (pending !== attempt) return
        pending = null
        attempt.result.success(mapOf(key to value))
    }

    private fun fail(attempt: Attempt, code: String) {
        if (pending !== attempt) return
        pending = null
        attempt.result.error(code, "Google sign-in could not complete", null)
    }

    fun close() {
        pending?.let { fail(it, "cancelled") }
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}

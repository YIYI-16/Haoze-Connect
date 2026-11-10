package com.follow.clash

import android.app.Activity
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
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
    private val channel = MethodChannel(messenger, "haoze/native_google")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "signIn") {
                result.notImplemented()
            } else if (pending != null) {
                result.error("busy", "Google sign-in is already running", null)
            } else {
                val clientId = call.argument<String>("serverClientId")
                val nonce = call.argument<String>("nonce")
                if (clientId.isNullOrBlank() || nonce.isNullOrBlank()) {
                    result.error("configuration", "Google sign-in is not configured", null)
                } else {
                    pending = result
                    scope.launch {
                        try {
                            val option = GetSignInWithGoogleOption.Builder(clientId).setNonce(nonce).build()
                            val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
                            val credential = CredentialManager.create(activity)
                                .getCredential(activity, request).credential
                            if (credential !is CustomCredential || credential.type !in setOf(
                                    GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL,
                                    GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_SIWG_CREDENTIAL,
                                )) {
                                pending?.error("credential", "Unexpected Google credential", null)
                            } else {
                                pending?.success(GoogleIdTokenCredential.createFrom(credential.data).idToken)
                            }
                        } catch (_: GetCredentialCancellationException) {
                            pending?.error("cancelled", "Google sign-in cancelled", null)
                        } catch (_: CancellationException) {
                            pending?.error("cancelled", "Google sign-in cancelled", null)
                        } catch (_: Exception) {
                            pending?.error("unavailable", "Google sign-in unavailable", null)
                        } finally {
                            pending = null
                        }
                    }
                }
            }
        }
    }

    fun close() {
        pending?.error("cancelled", "Google sign-in cancelled", null)
        pending = null
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}

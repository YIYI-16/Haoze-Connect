package com.follow.clash

import android.content.Intent
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeGoogleLogin: NativeGoogleLogin? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeGoogleLogin = NativeGoogleLogin(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(BatteryPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        ServiceState.attachFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (nativeGoogleLogin?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        nativeGoogleLogin?.close()
        nativeGoogleLogin = null
        flutterEngine?.let(ServiceState::detachFlutterEngine)
        super.onDestroy()
    }
}

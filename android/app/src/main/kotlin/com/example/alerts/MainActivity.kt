package com.example.alerts

import android.app.Activity
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.alerts/ringtone"
    private val PICK_RINGTONE_REQUEST = 999
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "pickRingtone") {
                // שמירת ה-Result כדי להחזיר תשובה אחרי שהמשתמש יבחר
                if (pendingResult != null) {
                    result.error("ALREADY_ACTIVE", "Ringtone picker is already active", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                
                // קבלת ה-URI הקיים (אם יש) כדי לסמן אותו כברירת מחדל בפתיחה
                val existingUriString = call.argument<String>("existingUri")
                val existingUri = if (existingUriString != null) Uri.parse(existingUriString) else null

                // הפעלת האינטנט המקורי של אנדרואיד לבחירת רינגטון (כולל השמעה!)
                val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                    putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
                    putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                    putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, true)
                    putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "בחר צליל התראה")
                    
                    if (existingUri != null) {
                        putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, existingUri)
                    }
                }
                
                startActivityForResult(intent, PICK_RINGTONE_REQUEST)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == PICK_RINGTONE_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uri: Uri? = data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
                // החזרת ה-URI (או null אם נבחר "שקט") לקוד ה-Dart
                pendingResult?.success(uri?.toString())
            } else {
                // המשתמש ביטל
                pendingResult?.success(null)
            }
            pendingResult = null
        }
    }
}
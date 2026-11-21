package com.carriez.flutter_hbb

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import ffi.FFI

class OpsLinxIdentityProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val app = requireNotNull(context)
        if (callingPackage != "de.opslinx.talx" ||
            app.packageManager.checkSignatures(app.applicationInfo.uid, Binder.getCallingUid()) !=
                PackageManager.SIGNATURE_MATCH
        ) {
            throw SecurityException("OpsTalX signature required")
        }

        val nonce = when (method) {
            "identity", "register" -> ""
            "signInbox" -> arg?.takeIf { NONCE.matches(it) } ?: return null
            else -> return null
        }
        // Same app_flutter directory as Android path_provider's documents directory.
        val dir = app.getDir("flutter", Context.MODE_PRIVATE).absolutePath
        return Bundle().apply {
            putString("value", FFI.talxInboxIdentity(dir, nonce, method == "register"))
        }
    }

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?
    ) = 0

    private companion object {
        val NONCE = Regex("[A-Za-z0-9_-]{43}")
    }
}

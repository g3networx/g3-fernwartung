package com.carriez.flutter_hbb

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.annotation.OptIn
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewStartUpConfig
import java.util.concurrent.Executors

class OpsTalxVideoActivity : Activity() {
    companion object {
        const val ROOM_URL = "opstalx_room_url"
        private const val CAMERA_REQUEST = 20
        private const val RETURN_TO_APP = "https://talx.opslinx.de/vas/return-to-app"
        private val room = Regex("(?:[0-9]{10}|[0-9a-f]{32})")
        private val grant = Regex("grant=[A-Za-z0-9_-]{1,1000}\\.[A-Za-z0-9_-]{86}")
        private val protectedRoom = Regex("vasKey=[A-Za-z0-9_-]{43}")
        private val webViewStartup = Executors.newSingleThreadExecutor()

        private fun hasTrustedOrigin(uri: Uri): Boolean =
            uri.scheme == "https" && uri.encodedAuthority == "talx.opslinx.de"

        fun canOpen(url: String): Boolean {
            val uri = Uri.parse(url)
            if (!hasTrustedOrigin(uri)) return false
            return when (uri.path) {
                "/vas/" -> (uri.encodedFragment == null || uri.encodedFragment?.let(protectedRoom::matches) == true) &&
                    uri.queryParameterNames == setOf("room") &&
                    uri.getQueryParameters("room").singleOrNull()?.let(room::matches) == true
                "/vas/launch" -> uri.encodedQuery == null &&
                    uri.encodedFragment?.let(grant::matches) == true
                else -> false
            }
        }
    }

    private var webView: WebView? = null
    private var pendingCamera: PermissionRequest? = null

    @OptIn(markerClass = [WebViewCompat.ExperimentalAsyncStartUp::class])
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(ROOM_URL)
        if (url == null || !canOpen(url)) {
            finish()
            return
        }
        val loading = ProgressBar(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(Button(this@OpsTalxVideoActivity).apply {
                setText(R.string.g3_video_help_close)
                setOnClickListener { finish() }
            }, LinearLayout.LayoutParams(-2, -2))
            addView(loading, LinearLayout.LayoutParams(-2, -2))
        }
        setContentView(layout)
        WebViewCompat.startUpWebView(WebViewStartUpConfig.Builder(webViewStartup).build()) {
            if (!isFinishing && !isDestroyed) {
                layout.removeView(loading)
                openRoom(layout, url)
            }
        }
    }

    private fun openRoom(layout: LinearLayout, url: String) {
        val view = WebView(this)
        webView = view
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            userAgentString = "$userAgentString OpsLinXAndroidVAS/1"
        }
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                if (url == RETURN_TO_APP) {
                    view.stopLoading()
                    finish()
                    return
                }
                super.onPageStarted(view, url, favicon)
            }

            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
                !hasTrustedOrigin(Uri.parse(url))

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (hasTrustedOrigin(request.url)) return false
                if (request.isForMainFrame && request.hasGesture() &&
                    request.url.toString() == "https://www.opslinx.de/") {
                    runCatching { startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                }
                return true
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                runOnUiThread {
                    if (!hasTrustedOrigin(request.origin) ||
                        PermissionRequest.RESOURCE_VIDEO_CAPTURE !in request.resources ||
                        isFinishing) {
                        request.deny()
                        return@runOnUiThread
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        request.grant(arrayOf(PermissionRequest.RESOURCE_VIDEO_CAPTURE))
                    } else if (pendingCamera == null) {
                        pendingCamera = request
                        requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_REQUEST)
                    } else {
                        request.deny()
                    }
                }
            }

            override fun onPermissionRequestCanceled(request: PermissionRequest) {
                if (pendingCamera === request) pendingCamera = null
            }
        }
        layout.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        view.loadUrl(url)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_REQUEST) return
        val request = pendingCamera ?: return
        pendingCamera = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && !isFinishing) {
            request.grant(arrayOf(PermissionRequest.RESOURCE_VIDEO_CAPTURE))
        } else {
            request.deny()
        }
    }

    override fun onResume() {
        super.onResume()
        webView?.onResume()
    }

    override fun onPause() {
        webView?.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        pendingCamera?.deny()
        pendingCamera = null
        webView?.let { view ->
            (view.parent as? LinearLayout)?.removeView(view)
            view.stopLoading()
            view.destroy()
        }
        webView = null
        super.onDestroy()
    }
}

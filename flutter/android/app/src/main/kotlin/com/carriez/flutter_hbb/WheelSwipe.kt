package com.carriez.flutter_hbb

internal data class WheelSwipe(val startY: Int, val endY: Int)

internal fun wheelSwipe(y: Int, travel: Int, height: Int): WheelSwipe {
    val lastY = height - 1
    val distance = travel.coerceIn(-lastY, lastY)
    val minStart = maxOf(0, -distance)
    val maxStart = minOf(lastY, lastY - distance)
    val start = y.coerceIn(minStart, maxStart)
    return WheelSwipe(start, start + distance)
}

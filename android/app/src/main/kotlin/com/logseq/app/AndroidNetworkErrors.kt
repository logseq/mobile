package com.logseq.app

import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

internal const val NETWORK_UNAVAILABLE = "network_unavailable"

internal fun isNetworkUnavailable(error: Throwable): Boolean =
    error is CognitoSessionUnavailableException || error is UnknownHostException ||
        error is ConnectException || error is NoRouteToHostException ||
        error is SocketTimeoutException || error is SocketException

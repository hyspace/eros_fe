package com.honjow.fehviewer.imagetransport;

import java.io.IOException;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.Socket;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.Collections;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;
import okhttp3.ConnectionSpec;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;

/**
 * Removable SNI compatibility transport. Only the SNI extension is omitted.
 * System CA chain verification and OkHttp's original-URL hostname verifier
 * remain enabled. There is deliberately no permissive trust/hostname callback.
 */
public final class NoSniClient {
    private NoSniClient() {}

    public static OkHttpClient create(int connectMs, int readMs, int totalMs)
            throws GeneralSecurityException {
        TrustManagerFactory managers =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        managers.init((KeyStore) null);
        X509TrustManager trust = null;
        for (TrustManager manager : managers.getTrustManagers()) {
            if (manager instanceof X509TrustManager) {
                trust = (X509TrustManager) manager;
                break;
            }
        }
        if (trust == null) throw new GeneralSecurityException("No system trust manager");
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, new TrustManager[] {trust}, null);
        return new OkHttpClient.Builder()
                .sslSocketFactory(new WithoutSni(context.getSocketFactory()), trust)
                // Do not let OkHttp re-enable SNI/ALPN after the socket is made.
                .connectionSpecs(Collections.singletonList(new ConnectionSpec.Builder(
                        ConnectionSpec.MODERN_TLS).supportsTlsExtensions(false).build()))
                .protocols(Collections.singletonList(Protocol.HTTP_1_1))
                .proxy(Proxy.NO_PROXY)
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .connectTimeout(connectMs, TimeUnit.MILLISECONDS)
                .readTimeout(readMs, TimeUnit.MILLISECONDS)
                .writeTimeout(connectMs, TimeUnit.MILLISECONDS)
                .callTimeout(totalMs, TimeUnit.MILLISECONDS)
                .build();
    }

    private static final class WithoutSni extends SSLSocketFactory {
        private final SSLSocketFactory delegate;
        WithoutSni(SSLSocketFactory delegate) { this.delegate = delegate; }
        private Socket configure(Socket socket) {
            SSLParameters parameters = ((SSLSocket) socket).getSSLParameters();
            parameters.setServerNames(Collections.emptyList());
            ((SSLSocket) socket).setSSLParameters(parameters);
            return socket;
        }
        @Override public String[] getDefaultCipherSuites() { return delegate.getDefaultCipherSuites(); }
        @Override public String[] getSupportedCipherSuites() { return delegate.getSupportedCipherSuites(); }
        @Override public Socket createSocket() throws IOException {
            return configure(delegate.createSocket());
        }
        @Override public Socket createSocket(Socket socket, String host, int port, boolean close)
                throws IOException {
            // Android Conscrypt ignores an empty SSLParameters.serverNames
            // list instead of clearing a hostname set by createSocket.
            // An IP literal suppresses SNI without hidden/reflection APIs.
            // OkHttp still verifies the certificate against the ORIGINAL URL
            // hostname, not this socket peer label, before sending HTTP.
            return configure(delegate.createSocket(
                    socket, socket.getInetAddress().getHostAddress(), port, close));
        }
        @Override public Socket createSocket(String host, int port) throws IOException {
            return createSocket(InetAddress.getByAddress(InetAddress.getByName(host).getAddress()), port);
        }
        @Override public Socket createSocket(String host, int port, InetAddress local, int localPort)
                throws IOException {
            return createSocket(InetAddress.getByAddress(InetAddress.getByName(host).getAddress()),
                    port, local, localPort);
        }
        @Override public Socket createSocket(InetAddress host, int port) throws IOException {
            return configure(delegate.createSocket(host, port));
        }
        @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort)
                throws IOException {
            return configure(delegate.createSocket(host, port, local, localPort));
        }
    }
}

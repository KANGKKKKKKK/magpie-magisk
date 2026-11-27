package com.ruin.magpie.tile;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.security.KeyStore;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/**
 * 安装器 Java 下载器的回归：本地 HTTPS 服务器 + 一次性证书。
 * 运行时需要 -Dmagpie.ks=<PKCS12> -Dmagpie.kspass=<口令>（由 run-jvm.sh 生成）。
 */
public final class FetchTest {
    private static int passed;
    private static int failed;

    private static void check(String name, boolean ok, String detail) {
        if (ok) passed++; else failed++;
        System.out.println((ok ? "  PASS  " : "  FAIL  ") + name + (ok ? "" : ": " + detail));
    }

    public static void main(String[] args) throws Exception {
        final byte[] body = new byte[200000];
        for (int i = 0; i < body.length; i++) body[i] = (byte) i;
        char[] pass = System.getProperty("magpie.kspass").toCharArray();
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (FileInputStream in = new FileInputStream(System.getProperty("magpie.ks"))) {
            ks.load(in, pass);
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, pass);
        SSLContext serverCtx = SSLContext.getInstance("TLS");
        serverCtx.init(kmf.getKeyManagers(), null, null);

        HttpServer plain = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        plain.createContext("/", ex -> { ex.sendResponseHeaders(200, 2); ex.getResponseBody().write("hi".getBytes()); ex.close(); });
        plain.start();
        final String plainBase = "http://127.0.0.1:" + plain.getAddress().getPort();

        HttpsServer secure = HttpsServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        secure.setHttpsConfigurator(new HttpsConfigurator(serverCtx));
        final String[] base = new String[1];
        secure.createContext("/", ex -> {
            String p = ex.getRequestURI().getPath();
            if (p.equals("/redirect")) {
                ex.getResponseHeaders().add("Location", base[0] + "/file");
                ex.sendResponseHeaders(302, -1);
            } else if (p.equals("/downgrade")) {
                ex.getResponseHeaders().add("Location", plainBase + "/file");
                ex.sendResponseHeaders(302, -1);
            } else if (p.equals("/loop")) {
                ex.getResponseHeaders().add("Location", base[0] + "/loop");
                ex.sendResponseHeaders(302, -1);
            } else if (p.equals("/missing")) {
                ex.sendResponseHeaders(404, -1);
            } else if (p.equals("/chunked")) {
                ex.sendResponseHeaders(200, 0);
                OutputStream os = ex.getResponseBody();
                os.write(body);
            } else {
                ex.sendResponseHeaders(200, body.length);
                ex.getResponseBody().write(body);
            }
            ex.close();
        });
        secure.start();
        base[0] = "https://127.0.0.1:" + secure.getAddress().getPort();

        File out = File.createTempFile("fetch", ".bin");
        out.deleteOnExit();
        String o = out.getPath();

        // 证书不受信：默认 trust store 里没有这张一次性证书，必须失败，绝不降级。
        check("拒绝不受信的证书", Fetch.run(new String[]{base[0] + "/file", o, "1000000", "5", "20"}) == 1, "");
        check("拒绝明文 http", Fetch.run(new String[]{plainBase + "/file", o, "1000000", "5", "20"}) == 3, "");
        check("拒绝带凭据的 URL", Fetch.run(new String[]{"https://u:p@127.0.0.1:1/x", o, "1000000", "5", "20"}) == 3, "");
        check("参数个数不对", Fetch.run(new String[]{"x"}) == 2, "");
        check("非正数参数", Fetch.run(new String[]{base[0], o, "0", "5", "20"}) == 2, "");

        // 信任这张证书后再测功能路径（等价于设备上系统 CA 认可服务器证书）。
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(ks);
        SSLContext clientCtx = SSLContext.getInstance("TLS");
        clientCtx.init(null, tmf.getTrustManagers(), null);
        HttpsURLConnection.setDefaultSSLSocketFactory(clientCtx.getSocketFactory());
        HttpsURLConnection.setDefaultHostnameVerifier((h, s) -> "127.0.0.1".equals(h));

        check("受信证书下载成功", Fetch.run(new String[]{base[0] + "/file", o, "1000000", "5", "20"}) == 0
                && java.util.Arrays.equals(Files.readAllBytes(out.toPath()), body), "");
        check("跟随 https 跳转", Fetch.run(new String[]{base[0] + "/redirect", o, "1000000", "5", "20"}) == 0
                && out.length() == body.length, "");
        check("拒绝跳转到 http", Fetch.run(new String[]{base[0] + "/downgrade", o, "1000000", "5", "20"}) == 3, "");
        check("跳转次数有上限", Fetch.run(new String[]{base[0] + "/loop", o, "1000000", "5", "20"}) == 4, "");
        check("HTTP 错误码失败", Fetch.run(new String[]{base[0] + "/missing", o, "1000000", "5", "20"}) == 4, "");
        check("声明长度超上限即拒绝", Fetch.run(new String[]{base[0] + "/file", o, "1000", "5", "20"}) == 5, "");
        check("未声明长度时边读边限", Fetch.run(new String[]{base[0] + "/chunked", o, "1000", "5", "20"}) == 5, "");

        plain.stop(0);
        secure.stop(0);
        System.out.println("FetchTest: " + passed + " passed, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}

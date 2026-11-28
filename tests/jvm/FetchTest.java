package com.ruin.magpie.tile;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.security.KeyStore;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
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

    private static void pause(CountDownLatch reached, CountDownLatch release) {
        reached.countDown();
        try { release.await(5, TimeUnit.SECONDS); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    private static void checkDeadline(String name, String url, String out, CountDownLatch reached,
                                      CountDownLatch release) {
        long start = System.nanoTime();
        int rc;
        try {
            rc = Fetch.run(new String[]{url, out, "1000", "8", "1"});
        } finally {
            release.countDown();
        }
        long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
        check(name, reached.getCount() == 0 && rc == 6 && ms < 3500, "rc=" + rc + ", elapsed=" + ms + "ms");
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
        CountDownLatch beforeHeaders = new CountDownLatch(1), sendHeaders = new CountDownLatch(1);
        CountDownLatch firstByte = new CountDownLatch(1), finishBody = new CountDownLatch(1);
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
            } else if (p.equals("/short")) {
                // 连接在正文写完前关闭；部分 JDK 报 EOF 而不抛异常。
                ex.getResponseHeaders().set("Connection", "close");
                ex.sendResponseHeaders(200, 20);
                ex.getResponseBody().write(1);
            } else if (p.equals("/slow-headers")) {
                pause(beforeHeaders, sendHeaders);
                ex.sendResponseHeaders(503, -1);
            } else if (p.equals("/slow-end")) {
                ex.sendResponseHeaders(200, 0);
                ex.getResponseBody().write(1);
                ex.getResponseBody().flush();
                pause(firstByte, finishBody);
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

        check("停滞秒数换算毫秒不能溢出", Fetch.run(new String[]{base[0], o, "1000", "2147484", "20"}) == 2, "");
        check("总秒数换算纳秒不能溢出", Fetch.run(new String[]{base[0], o, "1000", "5", "9223372036854775807"}) == 2, "");

        // 信任这张证书后再测功能路径（等价于设备上系统 CA 认可服务器证书）。
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(ks);
        SSLContext clientCtx = SSLContext.getInstance("TLS");
        clientCtx.init(null, tmf.getTrustManagers(), null);
        HttpsURLConnection.setDefaultSSLSocketFactory(clientCtx.getSocketFactory());

        check("受信证书下载成功", Fetch.run(new String[]{base[0] + "/file", o, "1000000", "5", "20"}) == 0
                && java.util.Arrays.equals(Files.readAllBytes(out.toPath()), body), "");
        check("跟随 https 跳转", Fetch.run(new String[]{base[0] + "/redirect", o, "1000000", "5", "20"}) == 0
                && out.length() == body.length, "");
        check("拒绝跳转到 http", Fetch.run(new String[]{base[0] + "/downgrade", o, "1000000", "5", "20"}) == 3, "");
        check("跳转次数有上限", Fetch.run(new String[]{base[0] + "/loop", o, "1000000", "5", "20"}) == 4, "");
        check("HTTP 错误码失败", Fetch.run(new String[]{base[0] + "/missing", o, "1000000", "5", "20"}) == 4, "");
        check("声明长度超上限即拒绝", Fetch.run(new String[]{base[0] + "/file", o, "1000", "5", "20"}) == 5, "");
        check("未声明长度时边读边限", Fetch.run(new String[]{base[0] + "/chunked", o, "1000", "5", "20"}) == 5, "");

        check("响应在声明长度前结束不能报下载成功",
                Fetch.run(new String[]{base[0] + "/short", o, "1000", "2", "5"}) == 1, "");
        check("即使底层只返回正常 EOF 也核对声明长度", Fetch.copy(new ByteArrayInputStream(new byte[]{1}),
                new ByteArrayOutputStream(), 20, 20, System.nanoTime() + TimeUnit.SECONDS.toNanos(5)) == 1, "");
        check("本地输出文件无法打开时如实失败", Fetch.run(new String[]{base[0] + "/file",
                out.getParent(), "1000000", "5", "20"}) == 1, "");

        checkDeadline("尚未收到 HTTP 响应头也受总时限约束", base[0] + "/slow-headers", o, beforeHeaders, sendHeaders);
        checkDeadline("已收到正文但 EOF 迟到也受总时限约束", base[0] + "/slow-end", o, firstByte, finishBody);

        plain.stop(0);
        secure.stop(0);
        System.out.println("FetchTest: " + passed + " passed, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}

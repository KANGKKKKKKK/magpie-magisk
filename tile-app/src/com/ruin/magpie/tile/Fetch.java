package com.ruin.magpie.tile;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

/**
 * 安装器在没有 curl 的设备上用的 HTTPS 下载器，由模块脚本通过
 * {@code CLASSPATH=<模块>/magpie-tile.apk app_process / com.ruin.magpie.tile.Fetch ...} 运行，
 * 不需要安装磁贴 App。
 *
 * 为什么不用 BusyBox wget：Magisk 自带的 wget 完全不校验证书（实测会打印
 * "TLS certificate validation not implemented"），不能拿来下 root 运行的二进制。
 * 这里走系统自带的 HttpsURLConnection（Conscrypt + 系统 CA），默认校验证书与主机名。
 *
 * 约束与 install.sh 里的 curl 参数一致：只允许 https、跳转也只能到 https、最多 5 次、
 * URL 不带用户名密码、有大小上限、连接/读取/总时长都有限。
 *
 * 用法：Fetch <url> <输出文件> <最大字节> <停滞秒数> <总秒数>
 * 退出码：0 成功；2 参数错误；3 地址不合规；4 HTTP 错误；5 超过大小；6 超时；1 其它失败。
 * 只使用 java.*，桌面 JVM 上也能跑单元测试。
 */
public final class Fetch {
    private static final int MAX_REDIRECTS = 5;

    private Fetch() {
    }

    public static void main(String[] args) {
        // 必须显式 exit：app_process 下主线程抛异常后运行时不一定退出。
        System.exit(run(args));
    }

    static int run(String[] args) {
        if (args.length != 5) {
            System.err.println("usage: Fetch <url> <out> <maxBytes> <stallSec> <totalSec>");
            return 2;
        }
        final long max;
        final int stall;
        final long total;
        try {
            max = Long.parseLong(args[2]);
            stall = Integer.parseInt(args[3]);
            total = Long.parseLong(args[4]);
        } catch (NumberFormatException e) {
            return 2;
        }
        if (max <= 0 || stall <= 0 || total <= 0) return 2;
        final long deadline = System.nanoTime() + total * 1_000_000_000L;
        File out = new File(args[1]);
        String url = args[0];
        try {
            for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
                if (!allowed(url)) {
                    System.err.println("refusing non-https or credentialed url");
                    return 3;
                }
                if (System.nanoTime() > deadline) return 6;
                HttpsURLConnection c = (HttpsURLConnection) new URL(url).openConnection();
                c.setInstanceFollowRedirects(false);
                c.setUseCaches(false);
                c.setConnectTimeout(stall * 1000);
                c.setReadTimeout(stall * 1000);
                c.setRequestProperty("User-Agent", "magpie-magisk-installer");
                c.setRequestProperty("Accept-Encoding", "identity");
                int code = c.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String loc = c.getHeaderField("Location");
                    c.disconnect();
                    if (loc == null) return 4;
                    url = new URL(new URL(url), loc).toString();
                    continue;
                }
                if (code != HttpURLConnection.HTTP_OK) {
                    System.err.println("HTTP " + code);
                    c.disconnect();
                    return 4;
                }
                long declared = c.getContentLengthLong();
                if (declared > max) {
                    c.disconnect();
                    return 5;
                }
                return copy(c, out, max, deadline);
            }
            System.err.println("too many redirects");
            return 4;
        } catch (java.net.SocketTimeoutException e) {
            System.err.println("timeout: " + e.getMessage());
            return 6;
        } catch (Exception e) {
            // 证书不受信、主机名不符等都会落到这里，绝不降级重试。
            System.err.println(e.getClass().getSimpleName() + ": " + e.getMessage());
            return 1;
        }
    }

    static boolean allowed(String url) {
        try {
            URL u = new URL(url);
            return "https".equals(u.getProtocol()) && u.getUserInfo() == null
                    && u.getHost() != null && !u.getHost().isEmpty();
        } catch (Exception e) {
            return false;
        }
    }

    private static int copy(HttpsURLConnection c, File out, long max, long deadline) throws Exception {
        long got = 0;
        byte[] buf = new byte[65536];
        try (InputStream in = c.getInputStream(); OutputStream os = new FileOutputStream(out)) {
            int n;
            while ((n = in.read(buf)) > 0) {
                got += n;
                if (got > max) return 5;
                if (System.nanoTime() > deadline) return 6;
                os.write(buf, 0, n);
            }
        } finally {
            c.disconnect();
        }
        return 0;
    }
}

package com.ruin.magpie.tile;

import java.io.Closeable;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
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
 * 输出是安装器负责清理的临时文件；只有退出码 0 才能使用它。
 * 退出码：0 成功；2 参数错误；3 地址不合规；4 HTTP 错误；5 超过大小；6 超时；1 其它失败。
 * 只使用 java.*，桌面 JVM 上也能跑单元测试。
 */
public final class Fetch {
    private static final int MAX_REDIRECTS = 5;
    private static final int MAX_SECONDS = Integer.MAX_VALUE / 1000;

    private Fetch() {
    }

    public static void main(String[] args) {
        // 含 DNS/TLS 等底层阻塞时也由专用 app_process 退出，不依赖 interrupt 能打断系统调用。
        System.exit(run(args));
    }

    static int run(String[] args) {
        if (args.length != 5) {
            System.err.println("usage: Fetch <url> <out> <maxBytes> <stallSec> <totalSec>");
            return 2;
        }
        final long max;
        final int stall, total;
        try {
            max = Long.parseLong(args[2]);
            stall = Integer.parseInt(args[3]);
            total = Integer.parseInt(args[4]);
        } catch (NumberFormatException e) {
            return 2;
        }
        if (max <= 0 || stall <= 0 || stall > MAX_SECONDS || total <= 0 || total > MAX_SECONDS) return 2;
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(total);
        // 连接/读取限时只管单次阻塞，不能限制整个重定向链、响应头或不断有数据到达的读取。
        try (Destination out = new Destination(args[1])) {
            FutureTask<Integer> task = new FutureTask<>(new Callable<Integer>() {
                @Override public Integer call() throws IOException {
                    return download(args[0], out, max, stall, deadline);
                }
            });
            Thread worker = new Thread(task, "magpie-fetch");
            worker.setDaemon(true);
            worker.start();
            try {
                return task.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS);
            } finally {
                task.cancel(true);
            }
        } catch (TimeoutException e) {
            System.err.println("download deadline exceeded");
            return 6;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return 1;
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            System.err.println(cause.getClass().getSimpleName());
            return cause instanceof SocketTimeoutException ? 6 : 1;
        } catch (IOException e) {
            System.err.println(e.getClass().getSimpleName());
            return 1;
        }
    }

    // 响应状态与声明大小通过后才打开文件。超时后，即便 DNS/读取稍后才返回，
    // 工作线程也不能重新打开安装器已清理或已交给下一轮下载的路径。
    private static final class Destination implements Closeable {
        private final File file;
        private OutputStream stream;
        private boolean closed;

        Destination(String path) { file = new File(path); }

        synchronized OutputStream open() throws IOException {
            if (closed) throw new IOException("download cancelled");
            stream = new FileOutputStream(file);
            return stream;
        }

        public synchronized void close() throws IOException {
            closed = true;
            if (stream != null) stream.close();
        }
    }

    private static int download(String url, Destination out, long max, int stall, long deadline) throws IOException {
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            if (!allowed(url)) {
                System.err.println("refusing non-https or credentialed url");
                return 3;
            }
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) return 6;
            int timeout = (int) Math.min(stall * 1000L, Math.max(1, TimeUnit.NANOSECONDS.toMillis(remaining)));
            HttpsURLConnection c = (HttpsURLConnection) new URL(url).openConnection();
            try {
                c.setInstanceFollowRedirects(false);
                c.setUseCaches(false);
                c.setConnectTimeout(timeout);
                c.setReadTimeout(timeout);
                c.setRequestProperty("User-Agent", "magpie-magisk-installer");
                c.setRequestProperty("Accept-Encoding", "identity");
                int code = c.getResponseCode();
                if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                    String loc = c.getHeaderField("Location");
                    if (loc == null || loc.trim().isEmpty()) return 4;
                    url = new URL(c.getURL(), loc).toString();
                    continue;
                }
                if (code != HttpURLConnection.HTTP_OK) {
                    System.err.println("HTTP " + code);
                    return 4;
                }
                long declared = c.getContentLengthLong();
                if (declared > max) return 5;
                try (InputStream in = c.getInputStream()) {
                    return copy(in, out.open(), max, declared, deadline);
                }
            } finally {
                c.disconnect();
            }
        }
        System.err.println("too many redirects");
        return 4;
    }

    static int copy(InputStream in, OutputStream os, long max, long declared, long deadline) throws IOException {
        byte[] buf = new byte[65536];
        long got = 0;
        for (int n; (n = in.read(buf)) != -1;) {
            if (deadline - System.nanoTime() <= 0) return 6;
            if (n > max - got) return 5;
            os.write(buf, 0, n);
            got += n;
        }
        if (deadline - System.nanoTime() <= 0) return 6;
        if (declared >= 0 && got != declared) {
            System.err.println("incomplete response body");
            return 1;
        }
        return 0;
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
}

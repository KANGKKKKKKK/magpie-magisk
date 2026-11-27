package com.ruin.magpie.tile;

import android.os.Handler;
import android.os.Looper;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;

/**
 * 通过 su 执行模块脚本。
 *
 * <p>为什么不自己解析 /data/adb 下的状态文件：那个目录是 0700 root，
 * 普通 App 连遍历都做不到。所以「读状态」也只能走 su。
 *
 * <p>su 的路径不写死：不同 Root 方案位置不同（Magisk 在 /debug_ramdisk，
 * KernelSU 在 /data/adb/ksu/bin，APatch 在 /data/adb/ap/bin）。
 * 按常见顺序试，哪个能跑通就用哪个。
 */
final class Shell {

    /** 模块里的启停脚本。 */
    static final String SERVICE = "/data/adb/modules/magpie/scripts/magpie.service";

    /** 模块目录，用来判断模块装没装。 */
    static final String MODULE_DIR = "/data/adb/modules/magpie";

    /**
     * 模块在不在 —— **只能通过 su 判断**。
     *
     * <p>{@code /data/adb} 是 {@code drwx------}（0700 root），普通 App 连这个目录
     * 都进不去，所以 {@code new File(MODULE_DIR).isDirectory()} 永远返回 false。
     * （{@code /data/adb/modules} 自己虽然是 0755，但父目录不给穿越权限，一样没用。）
     *
     * <p>因此把「模块在不在」和「服务状态」合成一条 su 命令，用哨兵字符串区分：
     * 只跑一次 su，既拿到结果也拿到模块是否存在的答案。
     */
    static final String NO_MODULE = "__magpie_nomodule__";

    /** 一条命令同时回答「模块在不在」与「服务状态」。 */
    /**
     * root 侧自己的时限，比客户端超时（20 秒）短一点。
     *
     * <p>客户端超时只能杀掉 su 客户端；Magisk 下 root shell 由守护进程派生，未必随之退出，
     * 磁贴显示「未知」时启停可能还在后台跑。toybox/busybox 都有 timeout，让 root 侧先结束。
     * 没有 timeout 时退回直接执行，行为与以前一致。
     */
    private static String bounded(String args) {
        return "if command -v timeout >/dev/null 2>&1; then timeout 18 sh " + SERVICE + " " + args
                + "; else sh " + SERVICE + " " + args + "; fi";
    }

    static String statusCommand() {
        return "if [ -d " + MODULE_DIR + " ]; then " + bounded("status")
                + "; else echo " + NO_MODULE + "; fi";
    }

    /** 不使用旧 toggle 的参数扩展：旧控制器会忽略参数并实际反转。 */
    static String toggleIfCommand(String expected) {
        final String operation;
        if ("running".equals(expected)) operation = "toggle-if running";
        else if ("stopped".equals(expected)) operation = "toggle-if stopped";
        else throw new IllegalArgumentException("unknown expected tile state");
        return "if [ -d " + MODULE_DIR + " ]; then " + bounded(operation)
                + "; else echo " + NO_MODULE + "; fi";
    }

    static String panelUrlCommand() {
        return "if [ -d " + MODULE_DIR + " ]; then " + bounded("panel-url")
                + "; else echo " + NO_MODULE + "; fi";
    }

    // Accept only a successful controller response with one local, credential-free HTTP URL.
    private static final java.util.regex.Pattern PANEL_URL = java.util.regex.Pattern.compile(
            "http://(127(?:\\.[0-9]{1,3}){3}|\\[::1\\]):([1-9][0-9]{0,4})/");

    static String verifiedPanelUrl(Result result) {
        if (result == null || !result.ok) return null;
        String url = result.trimmed();
        java.util.regex.Matcher match = PANEL_URL.matcher(url);
        if (!match.matches() || Integer.parseInt(match.group(2)) > 65535) return null;
        if (match.group(1).startsWith("127.")) {
            for (String octet : match.group(1).split("\\.")) {
                if ((octet.length() > 1 && octet.startsWith("0")) || Integer.parseInt(octet) > 255) return null;
            }
        }
        return url;
    }

    private static final String[] SU_CANDIDATES = {
            "su",
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/debug_ramdisk/su",
            "/data/adb/ksu/bin/su",
            "/data/adb/ap/bin/su",
    };

    /**
     * 执行 su 的线程池。
     *
     * <p>直接构造 ThreadPoolExecutor，不用 {@code Executors.newFixedThreadPool}：
     * 后者造出来的 keepAliveTime 是 0，而「核心线程可超时回收」要求它非 0，
     * 于是必须先 setKeepAliveTime 再 allowCoreThreadTimeOut —— 两句写反就抛
     * IllegalArgumentException，且发生在类初始化里，整个 App 起不来。
     * 一次给全参数就没有这个顺序依赖。
     *
     * <p>空闲 5 秒后释放工作线程，避免保留不必要的线程资源。
     * Android 进程何时回收由系统组件生命周期与进程管理决定，不能靠
     * Java daemon 标记保证，也不能假设收起控制中心就一定销毁进程。
     */
    private static final ThreadPoolExecutor POOL = new ThreadPoolExecutor(
            2, 2,
            5, java.util.concurrent.TimeUnit.SECONDS,
            new java.util.concurrent.LinkedBlockingQueue<Runnable>(),
            new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    Thread t = new Thread(r, "magpie-su");
                    t.setDaemon(true);
                    return t;
                }
            });

    static {
        POOL.allowCoreThreadTimeOut(true);
    }
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final SerialExecutor ORDERED = new SerialExecutor(POOL);

    /** 记住上一次成功的 su，省得每次都从头试。 */
    private static volatile String cachedSu;

    interface Callback<T> {
        void onResult(T result);
    }

    private Shell() {
    }

    /**
     * 后台执行命令，结果回到主线程。
     * 命令串会被拼成 sh -c '...'，所以调用方传进来的内容必须是自己的常量。
     */
    static void run(final String command, final Callback<Result> cb) {
        runOn(POOL, command, cb);
    }

    /** Persist ordered side effects without creating another permanent thread. */
    static void runSerial(final String command, final Callback<Result> cb) {
        runOn(ORDERED, command, cb);
    }

    private static void runOn(java.util.concurrent.Executor executor,
                              final String command, final Callback<Result> cb) {
        executor.execute(new Runnable() {
            @Override
            public void run() {
                final Result r = exec(command);
                MAIN.post(new Runnable() {
                    @Override
                    public void run() {
                        cb.onResult(r);
                    }
                });
            }
        });
    }

    /** 同步执行，只在后台线程里调用。 */
    static Result exec(String command) {
        return exec(command, TIMEOUT_MS);
    }

    static Result exec(String command, long timeoutMs) {
        String cached = cachedSu;
        if (cached != null) {
            Result r = execWith(cached, command, timeoutMs);
            // 业务命令的非零退出或超时不能自动重放（尤其 toggle）。只有 su 本身不可用
            // （找不到、被拒）时才丢弃缓存；toggle-if 返回 stale 这类正常非零不必重新探测所有候选。
            if (!r.ok && suUnavailable(r)) cachedSu = null;
            return r;
        }
        return execWith(null, command, timeoutMs);
    }

    private static Result execWith(String su, String command, long timeoutMs) {
        if (su == null) {
            for (String candidate : SU_CANDIDATES) {
                Result probe = execOnce(candidate, "id -u", Math.min(timeoutMs, 5000L));
                if (probe.ok && "0".equals(probe.out.trim())) {
                    cachedSu = candidate;
                    su = candidate;
                    break;
                }
            }
            if (su == null) {
                return new Result(false, "", "no su");
            }
        }
        return execOnce(su, command, timeoutMs);
    }

    /** su 客户端本身失败的迹象：找不到可执行文件、被拒绝。业务命令的非零退出不算。 */
    static boolean suUnavailable(Result r) {
        String e = r.err == null ? "" : r.err.toLowerCase(java.util.Locale.ROOT);
        return e.contains("error=2") || e.contains("no such file") || e.contains("permission denied")
                || e.contains("not allowed") || e.contains("denied");
    }

    /**
     * 用户在前台主动点「授权 root」：每个候选都给足时间等用户在弹窗里点允许。
     * 普通探测只等 5 秒，没点完就换下一个候选，结果是连续弹好几次授权框。
     * su 存在但被拒时不再尝试别的候选。
     */
    static void grant(final Callback<Result> cb) {
        POOL.execute(new Runnable() {
            @Override
            public void run() {
                Result last = new Result(false, "", "no su");
                for (String candidate : SU_CANDIDATES) {
                    Result r = execOnce(candidate, "id -u", GRANT_TIMEOUT_MS);
                    if (r.ok && "0".equals(r.trimmed())) {
                        cachedSu = candidate;
                        last = r;
                        break;
                    }
                    last = r;
                    String e = r.err == null ? "" : r.err;
                    if (!e.contains("error=2") && !e.contains("No such file")) break;
                }
                final Result done = last;
                MAIN.post(new Runnable() {
                    @Override
                    public void run() {
                        cb.onResult(done);
                    }
                });
            }
        });
    }

    private static final long GRANT_TIMEOUT_MS = 60000L;
    private static final long TIMEOUT_MS = 20000L;
    private static final int MAX_STREAM_BYTES = 65536;

    static Result execOnce(String su, String command, long timeoutMs) {
        Process p = null;
        StreamReader out = null;
        StreamReader err = null;
        boolean timedOut = false;
        try {
            p = new ProcessBuilder(su, "-c", command)
                    .redirectErrorStream(false)
                    .start();
            out = new StreamReader(p.getInputStream());
            err = new StreamReader(p.getErrorStream());
            out.start();
            err.start();
            if (!p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                timedOut = true;
                p.destroy();
                if (!p.waitFor(500, TimeUnit.MILLISECONDS)) {
                    p.destroyForcibly();
                    p.waitFor(500, TimeUnit.MILLISECONDS);
                }
            }
            out.join(1000L);
            err.join(1000L);
            out.close();
            err.close();
            String suffix = timedOut ? "command timed out" : "";
            return new Result(!timedOut && p.exitValue() == 0,
                    out.text(), joinError(err.text(), suffix));
        } catch (Exception e) {
            if (p != null) {
                p.destroyForcibly();
            }
            return new Result(false, out == null ? "" : out.text(),
                    joinError(err == null ? "" : err.text(), String.valueOf(e.getMessage())));
        } finally {
            if (out != null) out.interrupt();
            if (err != null) err.interrupt();
            if (p != null) p.destroyForcibly();
        }
    }

    private static String joinError(String first, String second) {
        if (first == null || first.length() == 0) return second == null ? "" : second;
        if (second == null || second.length() == 0) return first;
        return first + second;
    }

    /** 两个流必须同时消费，否则 stderr 管道写满后 su 永远不会退出。 */
    private static final class StreamReader extends Thread {
        private final InputStream in;
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private boolean truncated;

        StreamReader(InputStream in) {
            super("magpie-su-stream");
            this.in = in;
            setDaemon(true);
        }

        @Override
        public void run() {
            byte[] buffer = new byte[4096];
            try {
                int n;
                while ((n = in.read(buffer)) != -1) {
                    int room = MAX_STREAM_BYTES - bytes.size();
                    if (room > 0) bytes.write(buffer, 0, Math.min(room, n));
                    if (n > room) truncated = true;
                }
            } catch (Exception ignored) {
                // 进程销毁/超时关闭流是正常收尾；已有输出仍保留。
            }
        }

        String text() {
            try {
                String value = bytes.toString("UTF-8");
                return truncated ? value + "\n[output truncated]\n" : value;
            } catch (Exception e) {
                return "";
            }
        }

        void close() {
            try { in.close(); } catch (Exception ignored) { }
        }
    }

    static final class Result {
        final boolean ok;
        final String out;
        final String err;

        Result(boolean ok, String out, String err) {
            this.ok = ok;
            this.out = out;
            this.err = err;
        }

        String trimmed() {
            return out == null ? "" : out.trim();
        }
    }
}

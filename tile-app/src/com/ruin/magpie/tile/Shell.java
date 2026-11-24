package com.ruin.magpie.tile;

import android.os.Handler;
import android.os.Looper;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.ThreadFactory;

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
    static String statusCommand() {
        return "if [ -d " + MODULE_DIR + " ]; then sh " + SERVICE
                + " status; else echo " + NO_MODULE + "; fi";
    }

    /** 一条命令同时回答「模块在不在」与「切换结果」。 */
    static String toggleCommand() {
        return "if [ -d " + MODULE_DIR + " ]; then sh " + SERVICE
                + " toggle; else echo " + NO_MODULE + "; fi";
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
     * <p>必须是守护线程且允许空闲回收：否则点过一次磁贴后，这个池的核心线程
     * 会一直活着，Java 进程只要还有非守护线程就不会退出，表现为
     * 「用了一次磁贴，App 就常驻内存」。磁贴是绑定服务，收起控制中心后就该被
     * 销毁 —— 5 秒空闲回收后线程消失，进程没有其他组件时自然被系统回收。
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
        POOL.execute(new Runnable() {
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
        Result r = execWith(cachedSu, command);
        if (r.ok || cachedSu == null) {
            return r;
        }
        // 缓存的 su 失效了（换了 Root 方案 / 被卸载），重新找一遍
        cachedSu = null;
        return execWith(null, command);
    }

    private static Result execWith(String su, String command) {
        if (su == null) {
            for (String candidate : SU_CANDIDATES) {
                Result probe = execOnce(candidate, "id -u");
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
        return execOnce(su, command);
    }

    private static Result execOnce(String su, String command) {
        Process p = null;
        try {
            p = new ProcessBuilder(su, "-c", command)
                    .redirectErrorStream(false)
                    .start();
            String out = readAll(p.getInputStream());
            String err = readAll(p.getErrorStream());
            int code = p.waitFor();
            return new Result(code == 0, out, err);
        } catch (Exception e) {
            return new Result(false, "", String.valueOf(e.getMessage()));
        } finally {
            if (p != null) {
                p.destroy();
            }
        }
    }

    private static String readAll(InputStream in) throws Exception {
        StringBuilder sb = new StringBuilder();
        BufferedReader br = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line;
        while ((line = br.readLine()) != null) {
            sb.append(line).append('\n');
        }
        br.close();
        return sb.toString();
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

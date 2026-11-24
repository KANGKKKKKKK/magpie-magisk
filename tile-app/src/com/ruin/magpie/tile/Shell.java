package com.ruin.magpie.tile;

import android.os.Handler;
import android.os.Looper;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
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
     * <p>必须是守护线程且允许空闲回收 —— 否则点过一次磁贴后，这个池的核心线程
     * 会一直活着，Java 进程只要还有非守护线程就不会退出，表现为
     * 「用了一次磁贴，App 就常驻内存」。磁贴本身是绑定服务，收起控制中心
     * 就该被销毁，不该因为一个线程池把整个进程留住。
     *
     * <p>allowCoreThreadTimeOut(true) + 5 秒空闲回收：点击后线程很快消失，
     * 进程没有其他组件时自然被系统回收，不占内存也不耗电。
     */
    private static final ExecutorService POOL = Executors.newFixedThreadPool(2, new ThreadFactory() {
        @Override
        public Thread newThread(Runnable r) {
            Thread t = new Thread(r, "magpie-su");
            t.setDaemon(true);
            return t;
        }
    });

    static {
        // 顺序不能颠倒：allowCoreThreadTimeOut(true) 在 keepAliveTime 为 0 时
        // 会抛 IllegalArgumentException（"Core threads must have nonzero keep alive
        // times"），而且是在类初始化里抛，表现为 App 与磁贴一启动就崩。
        java.util.concurrent.ThreadPoolExecutor pool = (java.util.concurrent.ThreadPoolExecutor) POOL;
        pool.setKeepAliveTime(5, java.util.concurrent.TimeUnit.SECONDS);
        pool.allowCoreThreadTimeOut(true);
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

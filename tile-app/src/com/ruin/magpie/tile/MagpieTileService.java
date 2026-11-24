package com.ruin.magpie.tile;

import android.content.ComponentName;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/**
 * 控制中心磁贴。
 *
 * <p>三个回调的分工（参考 BoxProxy 的做法）：
 * <ul>
 *   <li>onStartListening：读一次服务状态，刷新显示。结果缓存几秒，
 *       免得用户反复展开控制中心时每次都 fork 一个 su。</li>
 *   <li>onClick：立刻显示「处理中」并置灰，然后后台执行 toggle。
 *       启动 magpie 要几秒，没有即时反馈用户会以为没点上。</li>
 *   <li>unlockAndRun：磁贴可以从锁屏拉下来，必须先解锁再动 root 命令。</li>
 * </ul>
 *
 * <p>磁贴不会主动弹 root 授权框（TileService 在后台跑，弹不出来）。
 * 所以用户必须先打开一次 App 完成授权，这里才有 root 可用。
 */
public class MagpieTileService extends TileService {

    /** 状态缓存有效期：这段时间内重复 onStartListening 不重复执行 su。 */
    private static final long CACHE_MS = 5000L;

    private static long cachedAt = 0L;
    private static String cachedState = null;

    @Override
    public void onStartListening() {
        super.onStartListening();

        long now = System.currentTimeMillis();
        if (cachedState != null && now - cachedAt < CACHE_MS) {
            render(cachedState);
            return;
        }
        render("working");
        Shell.run("sh " + Shell.SERVICE + " status", new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = classify(r, "stopped");
                cachedState = state;
                cachedAt = System.currentTimeMillis();
                render(state);
            }
        });
    }

    /**
     * 磁贴被移除 / 替换时，让服务自己结束。
     *
     * <p>注释里写过「收起控制中心就该被销毁」，但实际上系统只在磁贴被移除时
     * 解绑，单纯收起面板不会 —— 进程会留一阵。这里显式 stopSelf 收干净。
     */
    @Override
    public void onTileRemoved() {
        super.onTileRemoved();
        cachedState = null;
        cachedAt = 0L;
        stopSelf();
    }

    @Override
    public void onClick() {
        super.onClick();
        // 锁屏上点磁贴时先要求解锁；root 命令不该在锁屏状态执行
        unlockAndRun(new Runnable() {
            @Override
            public void run() {
                doToggle();
            }
        });
    }

    private void doToggle() {
        render("working");
        // 走 toggle：在跑就停、没跑就起。停止会写 .user_stopped，
        // 看门狗不会把用户主动停掉的服务又拉回来。
        Shell.run("sh " + Shell.SERVICE + " toggle", new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = classify(r, "stopped");
                cachedState = state;
                cachedAt = System.currentTimeMillis();
                render(state);
            }
        });
    }

    /**
     * 把 su 的返回结果翻译成磁贴状态。
     *
     * <p>判据是「输出」而不是退出码：su 成功把命令交给 sh 之后，退出码来自脚本
     * 本身，所以 `sh: 脚本不存在` 的 127 也带着非 0；只看 !ok 会把它误判成
     * 「没 root」，用户看到的提示完全对不上。
     *
     * <p>失败必须如实显示成「失败」。以前 toggle 失败会落到 else 分支被画成
     * 「已停止」—— 用户点了启动、其实没起来，界面上却是「已停止」，看不出出过事。
     */
    private static String classify(Shell.Result r, String wantPrefix) {
        String out = r.trimmed();
        // status 打印的是 "running (PID 123)"，toggle 打印的是裸 "running"，
        // 所以不能只用 endsWith。取最后一行再双向匹配。
        String last = out;
        int nl = out.lastIndexOf('\n');
        if (nl >= 0) {
            last = out.substring(nl + 1).trim();
        }
        if (last.equals("running") || last.startsWith("running ")) {
            return "running";
        }
        if (last.equals("stopped") || last.startsWith("stopped ")) {
            return "stopped";
        }
        if (last.equals("failed") || last.startsWith("failed ")) {
            return "failed";
        }
        // 输出为空且命令失败：这才是「根本没拿到 root / su 不可用」
        if (out.isEmpty() && !r.ok) {
            return "noroot";
        }
        // 有输出但认不出来（例如 status 打印了别的），沿用上次已知状态
        return wantPrefix;
    }

    /** 把状态画到磁贴上。 */
    private void render(String state) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        String label;
        String sub;
        int tileState;

        if ("running".equals(state)) {
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_running);
            tileState = Tile.STATE_ACTIVE;
        } else if ("stopped".equals(state)) {
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_stopped);
            tileState = Tile.STATE_INACTIVE;
        } else if ("noroot".equals(state)) {
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_no_root);
            tileState = Tile.STATE_UNAVAILABLE;
        } else if ("failed".equals(state)) {
            // 如实显示失败：不要画成「已停止」，否则用户以为只是没启动
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_failed);
            tileState = Tile.STATE_INACTIVE;
        } else if ("nomodule".equals(state)) {
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_unavailable);
            tileState = Tile.STATE_UNAVAILABLE;
        } else {
            // working：显示处理中，同时置灰防止连点
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_working);
            tileState = Tile.STATE_UNAVAILABLE;
        }

        tile.setLabel(label);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.setSubtitle(sub);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            tile.setStateDescription(sub);
        }
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_tile));
        tile.setState(tileState);
        tile.updateTile();
    }

    /**
     * 让 SystemUI 重新回调 onStartListening。
     * 服务在别处（App 里、命令行、看门狗）被启停后调用，磁贴才不会显示旧状态。
     */
    static void refresh(android.content.Context ctx) {
        cachedState = null;
        cachedAt = 0L;
        try {
            TileService.requestListeningState(
                    ctx, new ComponentName(ctx, MagpieTileService.class));
        } catch (Throwable ignored) {
            // 老系统或系统限制了调用，忽略即可：下次展开控制中心自然会刷新
        }
    }
}

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
                String state;
                if (!r.ok) {
                    state = "noroot";
                } else if (r.trimmed().startsWith("running")) {
                    state = "running";
                } else {
                    state = "stopped";
                }
                cachedState = state;
                cachedAt = System.currentTimeMillis();
                render(state);
            }
        });
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
                String state;
                if (!r.ok) {
                    state = "noroot";
                } else {
                    String out = r.trimmed();
                    if (out.endsWith("running")) {
                        state = "running";
                    } else if (out.endsWith("stopped")) {
                        state = "stopped";
                    } else {
                        state = "stopped";
                    }
                }
                cachedState = state;
                cachedAt = System.currentTimeMillis();
                render(state);
            }
        });
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

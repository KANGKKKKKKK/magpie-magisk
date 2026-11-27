package com.ruin.magpie.tile;

import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import java.lang.ref.WeakReference;

/**
 * 控制中心磁贴。
 *
 * <p>三个回调的分工（参考 BoxProxy 的做法）：
 * <ul>
 *   <li>onStartListening：读一次服务状态，刷新显示。结果缓存几秒，
 *       免得用户反复展开控制中心时每次都 fork 一个 su。</li>
 *   <li>onClick：立刻显示「处理中」并置灰，只在控制器确认实际状态与画面一致后才启停。
 *       启动 magpie 要几秒，没有即时反馈用户会以为没点上。</li>
 *   <li>unlockAndRun：磁贴可以从锁屏拉下来，必须先解锁再动 root 命令。</li>
 * </ul>
 *
 * <p>磁贴不会主动弹 root 授权框（TileService 在后台跑，弹不出来）。
 * 所以用户必须先打开一次 App 完成授权，这里才有 root 可用。
 *
 * <p>还有一项不在本类能力范围内的坑：MIUI / HyperOS 的冻结类模块会把本 App
 * 的进程冻住（cgroup.freeze=1）。冻结期间 SystemUI 的 onStartListening
 * 根本到不了这里 —— 连 su 都不会执行，磁贴就停在最后一次画出的状态上，
 * 表现为「磁贴和运行状态不符」。本类只能做到「不把已经知道的状态丢掉」
 * （见 render 的重试、TileState 的缓存），根治要把本 App 加进冻结白名单。
 */
public class MagpieTileService extends TileService {

    /** 状态缓存有效期：这段时间内重复 onStartListening 不重复执行 su。 */
    private static final long CACHE_MS = 5000L;

    // Accessed only on the main thread; includes request generations and a busy guard.
    private static final TileState STATE = new TileState();
    // A command can outlive its Service instance; completion belongs to the current listener.
    private static WeakReference<MagpieTileService> currentListener = new WeakReference<>(null);
    private boolean listening;
    private long listenEpoch;
    private String paintedState;

    /**
     * 拿不到 Tile 对象时的重试间隔。
     *
     * <p>onStartListening 刚进来时，SystemUI 那边的 CustomTile 偶尔还没挂好，
     * getQsTile() 返回 null。以前这里直接 return：那次刷新就永久丢了，
     * 磁贴停在旧状态上，用户看到的就是「显示和实际不一致」。
     * 改成短间隔重试几次，正常情况下第一次就成功，不会有额外开销。
     */
    private static final long[] RETRY_MS = {60L, 150L, 400L, 900L};

    /** 最新一次 render 的序号：延迟重试只在序号仍是最新时生效，免得旧状态盖掉新状态。 */
    private static long renderSeq = 0L;

    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        super.onStartListening();

        if (!isCurrentListener()) {
            ++listenEpoch;
            paintedState = null;
        }
        listening = true;
        currentListener = new WeakReference<>(this);
        if (STATE.isBusy()) {
            render("working");
            return;
        }
        String fresh = STATE.freshState(SystemClock.elapsedRealtime(), CACHE_MS);
        if (fresh != null) {
            render(fresh);
            return;
        }
        readStatus();
    }

    private void readStatus() {
        if (!isCurrentListener()) return;
        // Keep a known value visible while reading; never invent 'stopped'.
        render(STATE.lastState() != null ? STATE.lastState() : "working");
        final long request = STATE.beginRead();
        if (request == -1L) return; // Coalesce repeated SystemUI callbacks.
        Shell.run(Shell.statusCommand(), new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = classifyStatus(r);
                if (STATE.completeRead(request, state, SystemClock.elapsedRealtime())) {
                    renderCurrent(state);
                }
            }
        });
    }

    @Override
    public void onStopListening() {
        clearListeningInstance();
        super.onStopListening();
    }

    @Override
    public void onDestroy() {
        clearListeningInstance();
        super.onDestroy();
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
        clearListeningInstance();
        STATE.invalidateCache();
        stopSelf();
    }

    @Override
    public void onClick() {
        super.onClick();
        if (!isCurrentListener() || STATE.isBusy()) return;
        final String expected = paintedState;
        final long epoch = listenEpoch;
        final long paint = renderSeq;
        // 锁屏点按可能延迟到下一次展开。保留点击时实际绘制的状态，而非解锁后的新画面。
        unlockAndRun(new Runnable() {
            @Override
            public void run() {
                applyClick(expected, epoch, paint);
            }
        });
    }

    private void applyClick(String expected, long epoch, long paint) {
        if (!isCurrentListener() || epoch != listenEpoch || STATE.isBusy()) return;
        if (paint != renderSeq || (!"running".equals(expected) && !"stopped".equals(expected))
                || !expected.equals(STATE.freshState(SystemClock.elapsedRealtime(), CACHE_MS))) {
            readStatus();
            return;
        }
        final long request = STATE.beginToggle();
        if (request == -1L) return;
        render("working");
        Shell.run(Shell.toggleIfCommand(expected), new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = classify(r);
                if (!STATE.completeToggle(request, state, SystemClock.elapsedRealtime())) return;
                if ("unknown".equals(state) || (r != null && !r.ok && "stopped".equals(state))) {
                    // 失配、旧控制器拒绝以及超时都只重读。不降级到旧 toggle，也不重放动作。
                    STATE.invalidateCache();
                    MagpieTileService listener = currentListener.get();
                    if (listener != null) listener.readStatus();
                } else {
                    renderCurrent(state);
                }
            }
        });
    }

    static String classifyStatus(Shell.Result r) {
        String state = classify(r);
        return r != null && !r.ok && "stopped".equals(state) ? "unknown" : state;
    }

    /** Shared pure classifier; unknown execution results stay unknown. */
    static String classify(Shell.Result r) {
        return r == null ? "unknown" : TileState.classify(r.ok, r.out, r.err);
    }

    private boolean isCurrentListener() {
        return listening && currentListener.get() == this;
    }

    private void clearListeningInstance() {
        listening = false;
        ++listenEpoch;
        paintedState = null;
        // A late stop/destroy from an older instance must not clear its replacement
        // or invalidate the replacement's pending render retries. Never release busy here.
        if (currentListener.get() == this) {
            currentListener.clear();
            ++renderSeq;
        }
    }

    private static void renderCurrent(String state) {
        MagpieTileService listener = currentListener.get();
        if (listener != null) listener.render(state);
    }

    /** 把状态画到磁贴上。 */
    private void render(String state) {
        if (!isCurrentListener()) return;
        render(state, 0, ++renderSeq);
    }

    /**
     * 真正的绘制，拿不到 Tile 时按 RETRY_MS 重试。
     *
     * @param seq 发起这次绘制的序号；重试期间若已有更新的状态，本次直接放弃，
     *            否则慢的那次会把新的盖回去。
     */
    private void render(final String state, final int attempt, final long seq) {
        if (!isCurrentListener() || seq != renderSeq) {
            return;
        }
        Tile tile = getQsTile();
        if (tile == null) {
            // SystemUI 那边还没挂好 / 已经解绑：重试，但不要无限重试，
            // 面板真的关掉了就让它走完这几档结束。
            if (attempt < RETRY_MS.length) {
                MAIN.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        render(state, attempt + 1, seq);
                    }
                }, RETRY_MS[attempt]);
            }
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
        } else if ("unknown".equals(state)) {
            label = getString(R.string.tile_label);
            sub = getString(R.string.state_unknown);
            tileState = Tile.STATE_INACTIVE;
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
        paintedState = state;
    }

    /** 主动授权后仅刷新当前实例；非 ACTIVE_TILE 不能依赖 requestListeningState。 */
    static void refresh(android.content.Context ctx) {
        STATE.invalidateCache();
        MagpieTileService listener = currentListener.get();
        if (listener != null && !STATE.isBusy()) listener.readStatus();
    }
}

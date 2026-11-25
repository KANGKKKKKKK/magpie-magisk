package com.ruin.magpie.tile;

import android.content.ComponentName;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
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
 *
 * <p>还有一项不在本类能力范围内的坑：MIUI / HyperOS 的冻结类模块会把本 App
 * 的进程冻住（cgroup.freeze=1）。冻结期间 SystemUI 的 onStartListening
 * 根本到不了这里 —— 连 su 都不会执行，磁贴就停在最后一次画出的状态上，
 * 表现为「磁贴和运行状态不符」。本类只能做到「不把已经知道的状态丢掉」
 * （见 render 的重试、resolve 的兜底），根治要把本 App 加进冻结白名单。
 */
public class MagpieTileService extends TileService {

    /** 状态缓存有效期：这段时间内重复 onStartListening 不重复执行 su。 */
    private static final long CACHE_MS = 5000L;

    private static long cachedAt = 0L;
    private static String cachedState = null;

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

        long now = System.currentTimeMillis();
        if (cachedState != null && now - cachedAt < CACHE_MS) {
            render(cachedState);
            return;
        }
        // 已知状态先顶上，完全没头绪才画「处理中」。
        // 以前是无条件画灰：su 慢一点（比如刚开机、root 授权还没下来），
        // 整块磁贴就会灰在那里显示「处理中」，看起来同样是状态不对。
        render(cachedState != null ? cachedState : "working");
        // 一条命令同时问「模块在不在」与「服务状态」：/data/adb 是 0700 root，
        // App 自己 stat 不到，只能让 su 去看。
        Shell.run(Shell.statusCommand(), new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = resolve(r);
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
        Shell.run(Shell.toggleCommand(), new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String state = resolve(r);
                cachedState = state;
                cachedAt = System.currentTimeMillis();
                render(state);
            }
        });
    }

    /**
     * 把 su 的返回结果翻成磁贴状态，认不出来时沿用上次已知状态。
     *
     * <p>宁可显示「上一次的结果」，也不能把「不知道」画成「已停止」：
     * 后者会让用户以为服务挂了，或者以为点了启动其实没起来，两头都是误导。
     */
    static String resolve(Shell.Result r) {
        String state = classify(r);
        if ("unknown".equals(state)) {
            return cachedState != null ? cachedState : "stopped";
        }
        return state;
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
     *
     * <p>返回 "unknown" 表示「有输出但认不出来」，由调用方决定怎么兜底。
     */
    static String classify(Shell.Result r) {
        String out = r.trimmed();
        // 模块不存在时命令会打印哨兵 —— 这条要在最前面判，
        // 否则会被后面「输出非空但认不出来」兜到旧状态。
        if (out.contains(Shell.NO_MODULE)) {
            return "nomodule";
        }
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
        return "unknown";
    }

    /** 把状态画到磁贴上。 */
    private void render(String state) {
        render(state, 0, ++renderSeq);
    }

    /**
     * 真正的绘制，拿不到 Tile 时按 RETRY_MS 重试。
     *
     * @param seq 发起这次绘制的序号；重试期间若已有更新的状态，本次直接放弃，
     *            否则慢的那次会把新的盖回去。
     */
    private void render(final String state, final int attempt, final long seq) {
        if (seq != renderSeq) {
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
     *
     * <p>服务在别处（App 里、命令行、看门狗）被启停后调用，磁贴才不会显示旧状态。
     * 注意：如果本进程被系统冻结，这个调用同样跑不到 —— 这是冻结模块的问题，
     * 不是这里的逻辑问题。
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

package com.ruin.magpie.tile;

import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;

/**
 * 桌面图标的显示 / 隐藏。
 *
 * <p>桌面入口挂在 activity-alias（{@code .Launcher}）上，所以「隐藏图标」
 * 就是把这个 alias 关掉：图标消失，但 MainActivity 本身仍然能被显式启动。
 * 这一点很关键 —— 如果把 MainActivity 关掉，用户就再也进不来这个设置页，
 * 也没法把图标恢复回来。
 *
 * <p>恢复入口有两处：
 * <ul>
 *   <li>磁贴长按（SystemUI 发 ACTION_QS_TILE_PREFERENCES，由 MainActivity 接住；
 *       TileService 本身没有 onLongClick）</li>
 *   <li>adb：{@code am start -n com.ruin.magpie.tile/.MainActivity}</li>
 * </ul>
 */
final class LauncherIcon {

    private static final String PREFS = "tile_prefs";
    private static final String KEY_HIDDEN = "launcher_hidden";

    private LauncherIcon() {
    }

    private static ComponentName alias(Context ctx) {
        return new ComponentName(ctx, "com.ruin.magpie.tile.Launcher");
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /** 当前是否隐藏。以系统实际状态为准，不只看记录 —— 用户可能在系统设置里改过。 */
    static boolean isHidden(Context ctx) {
        try {
            int state = ctx.getPackageManager()
                    .getComponentEnabledSetting(alias(ctx));
            if (state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                    || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER) {
                return true;
            }
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                return false;
            }
        } catch (Throwable ignored) {
            // 拿不到就退回记录值
        }
        return prefs(ctx).getBoolean(KEY_HIDDEN, false);
    }

    /**
     * 把系统状态同步回用户的意图。
     *
     * <p>组件启用状态是「系统侧」的，会在一些情况下被重置回 DEFAULT：
     * 覆盖安装、清除数据、部分系统更新、以及某些 Magisk 模块更新流程。
     * 一旦重置，隐藏过的图标就自己冒出来了 —— 而 App 里记的还是「已隐藏」，
     * 两边对不上。
     *
     * <p>所以每次 App 启动时对一次账：记录说「已隐藏」但系统是 DEFAULT/ENABLED，
     * 就重新隐藏；记录说「显示」而系统是 DISABLED，说明用户在系统设置里关掉了，
     * 尊重系统（不动），只把记录改成一致。
     *
     * @return 是否做了修正
     */
    static boolean reconcile(Context ctx) {
        SharedPreferences p = prefs(ctx);
        if (!p.contains(KEY_HIDDEN)) {
            return false;   // 用户从没设置过，不碰
        }
        boolean want = p.getBoolean(KEY_HIDDEN, false);
        try {
            int state = ctx.getPackageManager().getComponentEnabledSetting(alias(ctx));
            boolean systemHidden =
                    state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                            || state == PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER;
            boolean systemDefault = state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT;

            if (want && (systemDefault || !systemHidden)) {
                // 用户想要隐藏，但系统被重置了 → 重新隐藏（并补写标记）
                return setHidden(ctx, true);
            }
            if (want) {
                // 已经是隐藏的，但标记可能丢了（比如用户清了 App 数据）→ 补写
                writeFlag(true);
            }
            if (!want && systemHidden) {
                // 用户想要显示，但系统是禁用 —— 多半是用户自己在系统设置里关的，
                // 不擅自打开，只把记录对齐，避免下次又反过来改。
                //
                // 同时必须补写标记：否则这条链只覆盖了「在 App 里点隐藏」那一半。
                // 用户在系统设置里停用图标后，记录变成「已隐藏」而标记文件不存在；
                // 一旦系统重置（覆盖安装/清除数据/部分系统更新），开机时找不到标记
                // 就不会补隐藏，图标又冒出来 —— 正是 v1.2.2 要解决的那个场景。
                p.edit().putBoolean(KEY_HIDDEN, true).apply();
                writeFlag(true);
                return false;
            }
        } catch (Throwable ignored) {
            // 改不了就算了，界面上会显示当前真实状态
        }
        return false;
    }

    /**
     * 模块侧的标记文件。开机时由 service.sh 读它决定要不要重新隐藏图标。
     *
     * <p>为什么不用 App 自己的 SharedPreferences 当唯一依据：App 数据在 CE 存储，
     * 模块脚本跑在 Magisk 的 mount namespace 里看不到那条路径。放模块的 run 目录
     * 两边都能访问。
     */
    private static final String FLAG_DIR = "/data/adb/magpie/run";
    private static final String FLAG_NAME = ".tile_launcher_hidden";

    /** 设置显示 / 隐藏。返回是否成功。 */
    static boolean setHidden(Context ctx, boolean hidden) {
        try {
            ctx.getPackageManager().setComponentEnabledSetting(
                    alias(ctx),
                    hidden
                            ? PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                            : PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    // DONT_KILL_APP：改这个不影响运行中的进程，也就不打断当前界面
                    PackageManager.DONT_KILL_APP);
            prefs(ctx).edit().putBoolean(KEY_HIDDEN, hidden).apply();
            writeFlag(hidden);
            return true;
        } catch (Throwable e) {
            return false;
        }
    }

    /**
     * 把意图同步到模块目录（经 su）。失败不阻断主流程 ——
     * 只是开机时不会自动补隐藏，用户下次打开 App 仍会自己对账。
     */
    private static void writeFlag(boolean hidden) {
        final String cmd = hidden
                ? "mkdir -p " + FLAG_DIR + " && : > " + FLAG_DIR + "/" + FLAG_NAME
                + " && chmod 600 " + FLAG_DIR + "/" + FLAG_NAME
                : "rm -f " + FLAG_DIR + "/" + FLAG_NAME;
        Shell.run(cmd, new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                if (!r.ok) {
                    // 不能静默：写不进去时「开机自动恢复图标」不会生效，
                    // 只能等用户下次打开 App 时对账。留日志便于 logcat 定位。
                    android.util.Log.w("MagpieTile",
                            "标记文件写入失败，开机不会自动恢复隐藏: " + r.err);
                }
            }
        });
    }
}

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
 *   <li>磁贴长按（TileService 支持 onLongClick，打开本页）</li>
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
            return true;
        } catch (Throwable e) {
            return false;
        }
    }
}

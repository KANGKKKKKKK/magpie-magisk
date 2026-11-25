package com.ruin.magpie.tile;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowInsets;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * 极简界面：显示状态、请求 root、打开面板。
 *
 * <p>刻意不做设置项 —— 所有配置都在模块的 magpie.config 里，
 * 这里再做一份只会让两边打架。
 *
 * <p>它存在的另一个理由：TileService 在后台运行，弹不出 root 授权框，
 * 所以必须有一个前台界面让用户完成第一次授权。
 */
public class MainActivity extends Activity {

    private TextView status;
    private TextView hint;
    private Button grant;
    private Button launcherBtn;
    private TextView launcherNote;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 组件启用状态会被系统重置（覆盖安装、清除数据、部分系统更新），
        // 导致隐藏过的图标自己冒出来。每次打开 App 对一次账。
        // 放在 setContentView 之前：先把系统状态修正，再按真实状态渲染按钮。
        LauncherIcon.reconcile(this);
        setContentView(buildUi());
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
        refreshLauncherToggle();
    }

    private View buildUi() {
        int pad = dp(20);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        // targetSdk 35+ 强制 edge-to-edge，内容会顶到状态栏/导航栏下面。
        // 这里按系统 insets 让开，否则标题会被状态栏压住。
        final int basePad = pad;
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                android.graphics.Insets bars = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(basePad + bars.left, basePad + bars.top,
                        basePad + bars.right, basePad + bars.bottom);
                return insets;
            }
        });

        TextView intro = new TextView(this);
        intro.setText(R.string.intro);
        intro.setTextSize(16f);
        root.addView(intro);

        TextView detail = new TextView(this);
        detail.setText(R.string.intro_detail);
        detail.setTextSize(13f);
        detail.setAlpha(0.7f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        root.addView(detail, lp);

        TextView statusLabel = new TextView(this);
        statusLabel.setText(R.string.label_status);
        statusLabel.setTextSize(13f);
        statusLabel.setAlpha(0.7f);
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(24);
        root.addView(statusLabel, lp);

        status = new TextView(this);
        status.setTextSize(20f);
        root.addView(status);

        hint = new TextView(this);
        hint.setTextSize(13f);
        hint.setAlpha(0.7f);
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        root.addView(hint, lp);

        grant = new Button(this);
        grant.setText(R.string.btn_grant);
        grant.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestRoot();
            }
        });
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(24);
        root.addView(grant, lp);

        Button panel = new Button(this);
        panel.setText(R.string.btn_open_panel);
        panel.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openPanel();
            }
        });
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        root.addView(panel, lp);

        // ---- 桌面图标开关 ----
        TextView launcherLabel = new TextView(this);
        launcherLabel.setText(R.string.label_launcher);
        launcherLabel.setTextSize(13f);
        launcherLabel.setAlpha(0.7f);
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(28);
        root.addView(launcherLabel, lp);

        launcherBtn = new Button(this);
        launcherBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                toggleLauncher();
            }
        });
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        root.addView(launcherBtn, lp);

        launcherNote = new TextView(this);
        launcherNote.setTextSize(13f);
        launcherNote.setAlpha(0.7f);
        lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        root.addView(launcherNote, lp);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        return scroll;
    }

    private void refreshStatus() {
        status.setText("…");
        hint.setText(R.string.tile_hint);

        Shell.run(Shell.statusCommand(), new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                // 与磁贴共用同一套判定，避免「磁贴说启动失败、界面说需要 root」
                String state = MagpieTileService.classify(r);
                if ("noroot".equals(state)) {
                    status.setText(R.string.state_no_root);
                    hint.setText(R.string.root_needed);
                    grant.setVisibility(View.VISIBLE);
                    return;
                }
                grant.setVisibility(View.GONE);
                if ("running".equals(state)) {
                    status.setText(R.string.state_running);
                } else if ("failed".equals(state)) {
                    status.setText(R.string.state_failed);
                } else if ("nomodule".equals(state)) {
                    status.setText(R.string.state_unavailable);
                    hint.setText(R.string.module_missing);
                } else if ("unknown".equals(state)) {
                    // 有输出但认不出来：不要写成「已停止」，否则和磁贴一样会误导
                    status.setText("…");
                    hint.setText(R.string.tile_hint);
                } else {
                    status.setText(R.string.state_stopped);
                }
            }
        });
    }

    private void requestRoot() {
        grant.setEnabled(false);
        grant.setText("…");
        // 只是触发一次授权：真正要的是 su 弹窗，命令本身无所谓
        Shell.run("id -u", new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                grant.setEnabled(true);
                grant.setText(R.string.btn_grant);
                if (r.ok && "0".equals(r.trimmed())) {
                    MagpieTileService.refresh(MainActivity.this);
                    refreshStatus();
                } else {
                    status.setText(R.string.root_failed);
                }
            }
        });
    }

    private void openPanel() {
        // 面板地址写在模块的 run/web.url 里，带访问密码
        Shell.run("cat /data/adb/magpie/run/web.url", new Shell.Callback<Shell.Result>() {
            @Override
            public void onResult(Shell.Result r) {
                String url = r.trimmed();
                if (url.isEmpty()) {
                    // 服务没起时没有这个文件，退回到不带密码的地址
                    url = "http://127.0.0.1:3430/";
                }
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)));
                } catch (Throwable ignored) {
                    // 没有浏览器就什么都不做
                }
            }
        });
    }

    /** 按当前状态刷新「隐藏/显示桌面图标」按钮与提示。 */
    private void refreshLauncherToggle() {
        boolean hidden = LauncherIcon.isHidden(this);
        launcherBtn.setText(hidden ? R.string.btn_show_icon : R.string.btn_hide_icon);
        launcherNote.setText(hidden ? getString(R.string.launcher_hidden_note) : "");
        launcherNote.setVisibility(hidden ? View.VISIBLE : View.GONE);
    }

    private void toggleLauncher() {
        boolean hidden = LauncherIcon.isHidden(this);
        if (!LauncherIcon.setHidden(this, !hidden)) {
            launcherNote.setText(R.string.launcher_hide_failed);
            launcherNote.setVisibility(View.VISIBLE);
            return;
        }
        refreshLauncherToggle();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}

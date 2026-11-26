package com.ruin.magpie.tile;

/*
 * 直接编译生产 SelfCheck，不复制判定逻辑，也不依赖 Android/Shell。
 *
 *   javac -encoding UTF-8 tile-app/src/com/ruin/magpie/tile/SelfCheck.java \
 *         tests/jvm/SelfCheckTest.java -d /tmp/cls
 *   java -cp /tmp/cls com.ruin.magpie.tile.SelfCheckTest
 *
 * 退出码非 0 表示有断言失败；PASS 行保持兼容现有用例计数脚本。
 */
public class SelfCheckTest {

    private static int failed = 0;
    private static int checks = 0;
    private static int scenarios = 0;

    // 所有正常夹具均带完成标记；不完整输出的回归会显式删掉或损坏它。
    private static final String HEALTHY = "mod=1\nsvc=running\ninstalled=1\nuid=10330\n"
            + "vcode=9\nmagisk=2\ninqs=1\npainted=运行中\nalive=0\nfrozen=0\n"
            + "freezer=NoActive\ndone=1";

    private static void has(String name, String out, String expect) {
        check(name, out.contains(expect), "含「" + expect + "」", out);
    }

    private static void not(String name, String out, String expect) {
        check(name, !out.contains(expect), "不含「" + expect + "」", out);
    }

    private static void check(String name, boolean pass, String description, String out) {
        checks++;
        if (!pass) failed++;
        System.out.printf("  %-6s %-28s %s%s%n", pass ? "PASS" : "FAIL", name,
                description, pass ? "" : "，实际：\n" + out);
    }

    private static String run(String raw) {
        return run(raw, true, null);
    }

    private static String run(String raw, boolean succeeded, String error) {
        scenarios++;
        SelfCheck parsed = error == null ? SelfCheck.parse(raw, succeeded)
                : SelfCheck.parse(raw, succeeded, error);
        StringBuilder sb = new StringBuilder();
        for (String line : parsed.report()) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(line);
        }
        return sb.toString();
    }

    private static String field(String key, String value) {
        return field(HEALTHY, key, value);
    }

    /** 替换或移除单个字段；夹具拼错键时直接失败，防止回归用例没覆盖目标。 */
    private static String field(String raw, String key, String value) {
        StringBuilder sb = new StringBuilder();
        boolean found = false;
        for (String line : raw.split("\n")) {
            if (line.startsWith(key + "=")) {
                found = true;
                if (value == null) continue;
                line = key + "=" + value;
            }
            if (sb.length() > 0) sb.append('\n');
            sb.append(line);
        }
        if (!found) throw new AssertionError("夹具没有字段：" + key);
        return sb.toString();
    }

    private static void baseline() {
        String r = run("mod=0\ndone=1");
        has("模块不在", r, "没找到 magpie 模块");
        not("模块不在-不报健康", r, "✓");
        has("旧版模块", run("mod=1\nold=1\ndone=1"), "模块是旧版");

        r = run(HEALTHY);
        has("正常-服务在跑", r, "Magpie 服务正在运行");
        has("正常-root已授权", r, "root 已授权");
        has("正常-显示一致", r, "和实际一致");
        has("正常-进程未运行", r, "展开时才拉起");
        not("正常-无警告", r, "被冻结");
        not("正常-无未知", r, "未知");

        r = run(field("svc", "stopped"));
        has("不一致-服务停止", r, "Magpie 服务没有运行");
        has("不一致-提示实际已停止", r, "实际是「已停止」");
        has("不一致-说明原因", r, "磁贴还没重读");
        has("一致-已停止", run(field(field("svc", "stopped"), "painted", "已停止")),
                "和实际一致");
        has("不一致-提示实际运行中", run(field("painted", "已停止")), "实际是「运行中」");

        r = run(field("magisk", "1"));
        has("root被拒", r, "root 被拒绝了");
        has("root被拒-给路径", r, "超级用户");
        r = run(field(field("magisk", "0"), "painted", "需要 root"));
        has("root未授权", r, "root 还没授权");
        has("显示需要root", r, "磁贴显示「需要 root」");

        r = run(field("inqs", "0"));
        has("不在面板", r, "磁贴不在控制中心");
        not("不在面板-不谈绘制", r, "磁贴显示");
        has("未绘制-null", run(field("painted", "null")), "磁贴还没画出状态");
        has("未绘制-空值", run(field("painted", "")), "磁贴还没画出状态");
        has("处理中-正常", run(field("painted", "处理中…")), "正在刷新");

        r = run(field(field("alive", "1"), "frozen", "1"));
        has("冻结-报出来", r, "磁贴进程被冻结");
        has("冻结-指出NoActive", r, "NoActive");
        has("冻结-给办法", r, "白名单");
        for (String source : new String[] {"system", "CZero", "greezer"}) {
            String label = "system".equals(source) ? "系统的空闲冻结" : source;
            has("冻结-" + source,
                    run(field(field(field("alive", "2"), "frozen", "1"), "freezer", source)),
                    label);
        }
        for (String source : new String[] {"", "unknown", null}) {
            r = run(field(field(field("alive", "1"), "frozen", "1"), "freezer", source));
            has("冻结-未知来源-" + source, r, "加进冻结类模块的白名单");
            not("冻结-未知不瞎猜-" + source, r, "疑似");
        }
        has("显示模块未安装", run(field("painted", "模块未安装")), "磁贴显示「模块未安装」");
        has("显示启动失败", run(field("painted", "启动失败")), "磁贴显示「启动失败」");
        has("进程未冻结", run(field("alive", "1")), "磁贴进程没被冻结");
    }

    private static void executionAndCompletion() {
        for (String raw : new String[] {null, "", " \n\r\n "}) {
            String r = run(raw);
            has("空输出-未知-" + raw, r, "未知");
            not("空输出-不报健康-" + raw, r, "✓");
            not("空输出-不推断没root-" + raw, r, "拿不到 root 权限");
            not("空输出-不建议重装-" + raw, r, "重装");
        }
        String r = run(null, false, null);
        has("回调无结果-明确执行失败", r, "命令执行失败");
        not("回调无结果-不推断没root", r, "未能获得 root 执行环境");
        not("回调无结果-不报健康", r, "✓");
        r = run(null, false, "no su");
        has("root执行环境缺失", r, "未能获得 root 执行环境");
        not("缺root-不报健康", r, "✓");

        r = run(HEALTHY, false, "command timed out");
        has("超时-即使输出完整也未知", r, "自查命令超时");
        not("超时-不报健康", r, "✓");
        not("超时-不采信服务", r, "Magpie 服务正在运行");
        not("超时-不建议重装", r, "重装");
        r = run("mod=0", false, "command timed out");
        has("超时-部分输出", r, "超时");
        not("超时-不采信缺模块", r, "没找到 magpie 模块");

        for (String error : new String[] {null, "permission denied while reading file", "exit 7"}) {
            r = run(HEALTHY, false, error);
            has("执行失败-" + error, r, "命令执行失败");
            not("执行失败-不报健康-" + error, r, "✓");
            not("执行失败-不误报拒绝root-" + error, r, "root 被拒绝");
            not("执行失败-不建议重装-" + error, r, "重装");
        }
        r = run("mod=0\ndone=1", false, "exit 2");
        has("失败完整输出-先报执行失败", r, "命令执行失败");
        not("失败完整输出-不采信缺模块", r, "没找到 magpie 模块");
        r = run(HEALTHY, false, "interrupted");
        has("中断-明确分类", r, "已中断");
        not("中断-不报健康", r, "✓");

        for (String raw : new String[] {field("done", null), "mod=1\nsvc=running",
                "mod=0", "mod=1\nold=1", field("done", "0"), field("done", "unknown"),
                HEALTHY + "\ndone=1", HEALTHY + "\nmod=0", HEALTHY + "\n[output truncated]"}) {
            r = run(raw);
            has("不完整协议-明确提示", r, "自查输出不完整");
            not("不完整协议-不报健康", r, "✓");
            not("不完整协议-不建议刷模块", r, "先刷入模块");
            not("不完整协议-不建议更新模块", r, "更新模块后");
        }
        r = run(HEALTHY, true, "[output truncated]");
        has("stderr截断-结果未知", r, "自查输出不完整");
        not("stderr截断-不报健康", r, "✓");
        r = run("done=1");
        has("仅完成标记-模块未知", r, "模块安装状态未知");
        has("仅完成标记-服务未知", r, "读不到服务状态");
        has("仅完成标记-安装未知", r, "App 安装状态未知");
        not("仅完成标记-不报健康", r, "✓");

        r = run(HEALTHY.replace("\n", "\r\n") + "\r\n \r\n");
        has("CRLF与末尾空白-正常", r, "和实际一致");
        not("CRLF与末尾空白-不误报缺标记", r, "输出不完整");
        r = run(HEALTHY, true, "optional tool warning");
        has("非致命stderr-保留已知结论", r, "Magpie 服务正在运行");
    }

    private static void unknownFields() {
        String r;
        for (String value : new String[] {"unknown", "failed", "", "Running", null}) {
            for (String painted : new String[] {"运行中", "已停止"}) {
                r = run(field(field("svc", value), "painted", painted));
                has("未知服务-" + value + "/" + painted, r, "读不到服务状态");
                has("未知服务-显示仍有用", r, "磁贴显示「" + painted + "」");
                not("未知服务-不比较一致", r, "和实际一致");
                not("未知服务-不推断实际状态", r, "实际是");
            }
        }
        for (String value : new String[] {"unknown", "", "2", "-1", "1oops", null}) {
            r = run(field("installed", value));
            has("安装未知-" + value, r, "App 安装状态未知");
            has("安装未知-保留服务证据", r, "Magpie 服务正在运行");
            not("安装未知-不建议重装", r, "重装");
            not("安装未知-不说未安装", r, "未检测到磁贴 App");
            not("安装未知-不检查进程健康", r, "✓ 磁贴进程");
        }
        r = run(field("installed", "0"));
        has("明确未安装-报安装记录缺失", r, "未检测到磁贴 App 的安装记录");
        not("明确未安装-不检查进程", r, "✓ 磁贴进程");

        for (String value : new String[] {"unknown", "", "2", null}) {
            r = run(field("mod", value));
            has("模块未知-" + value, r, "模块安装状态未知");
            not("模块未知-不推断未安装", r, "没找到 magpie 模块");
            has("模块未知-其他已知项仍显示", r, "Magpie 服务正在运行");
        }
        r = run("mod=unknown\ndone=1");
        has("fallback目录不可读-未知", r, "模块安装状态未知");
        not("fallback目录不可读-不要求刷模块", r, "先刷入模块");

        for (String value : new String[] {"unknown", "", "2", null}) {
            r = run(field("inqs", value));
            has("控制中心未知-" + value, r, "无法确认磁贴是否在控制中心");
            not("控制中心未知-不推断不在", r, "磁贴不在控制中心");
            not("控制中心未知-不比较显示", r, "和实际一致");
        }
        for (String value : new String[] {"unknown", null}) {
            r = run(field("painted", value));
            has("绘制未知-" + value, r, "磁贴显示状态未知");
            not("绘制未知-不当作未绘制", r, "磁贴还没画出状态");
            not("绘制未知-不比较", r, "实际是");
        }
        r = run(field("painted", "unrecognized"));
        has("未识别标签-保留原值", r, "unrecognized");
        not("未识别标签-不推断不一致", r, "实际是");

        for (String value : new String[] {"unknown", "absent", "", "3", "2x", null}) {
            r = run(field("magisk", value));
            has("可选Magisk未知-" + value, r, "授权记录未知");
            has("可选Magisk未知-服务仍正常", r, "Magpie 服务正在运行");
            has("可选Magisk未知-进程仍正常", r, "展开时才拉起");
            not("可选Magisk未知-不说已授权", r, "root 已授权");
            not("可选Magisk未知-不说被拒", r, "root 被拒绝");
            not("可选Magisk未知-不算命令失败", r, "命令执行失败");
        }

        for (String key : new String[] {"mod", "svc", "installed", "inqs", "painted", "alive", "frozen"}) {
            r = run(HEALTHY.replace("done=1", key + "=0\ndone=1"));
            has("重复字段-" + key, r, "未知");
            if ("alive".equals(key) || "frozen".equals(key)) {
                not("重复计数-不报进程健康-" + key, r, "✓ 磁贴进程");
            } else if ("svc".equals(key) || "inqs".equals(key) || "painted".equals(key)) {
                not("重复字段-不比较一致-" + key, r, "和实际一致");
            }
        }
    }

    private static void invalidCounts() {
        for (String invalid : new String[] {null, "", "unknown", "oops", "-1", "+1", "1.0",
                "2147483648", "1e3"}) {
            for (String key : new String[] {"alive", "frozen"}) {
                String raw = "frozen".equals(key) ? field("alive", "1") : HEALTHY;
                String r = run(field(raw, key, invalid));
                has("非法计数-" + key + "/" + invalid, r, "进程/冻结状态未知");
                not("非法计数-不报进程健康", r, "✓ 磁贴进程");
                not("非法计数-不报已冻结", r, "进程被冻结了");
                has("非法计数-独立服务状态仍有用", r, "Magpie 服务正在运行");
            }
        }
        String r = run(field("frozen", "unknown"));
        has("零进程但冻结查询失败-仍未知", r, "进程/冻结状态未知");
        not("零进程但冻结查询失败-不报健康", r, "✓ 磁贴进程");
        not("零进程但冻结查询失败-不说按需启动", r, "展开时才拉起");
        r = run(field("frozen", "1"));
        has("计数矛盾-零进程一冻结", r, "进程/冻结状态未知");
        not("计数矛盾-不报进程健康", r, "✓ 磁贴进程");
        not("计数矛盾-不报已冻结", r, "进程被冻结了");
        r = run(field(field("alive", "1"), "frozen", "2"));
        has("计数矛盾-冻结数大于进程数", r, "进程/冻结状态未知");
        r = run(field("alive", "2147483647"));
        has("计数上界-未冻结", r, "磁贴进程没被冻结");
        r = run(field(field("alive", "2147483647"), "frozen", "2147483647"));
        has("计数上界-已冻结", r, "磁贴进程被冻结");
    }

    private static void fallbackProtocol() {
        String command = SelfCheck.command();
        has("旧模块fallback-完整标记", command, "echo mod=1; echo old=1; echo done=1;");
        has("缺模块fallback-完整标记", command, "echo mod=0; echo done=1;");
        has("不可读fallback-保留未知", command, "echo mod=unknown; echo done=1;");
        has("已有脚本-不掩盖脚本退出码", command,
                "then sh /data/adb/modules/magpie/scripts/tile-check.sh; elif");
    }

    public static void main(String[] args) {
        baseline();
        executionAndCompletion();
        unknownFields();
        invalidCounts();
        fallbackProtocol();
        System.out.println("\n" + scenarios + " 个自查输入场景，" + checks + " 条断言，"
                + failed + " 条失败");
        if (failed > 0) System.exit(1);
        System.out.println("全部通过");
    }
}

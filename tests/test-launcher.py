#!/usr/bin/env python3
"""Exercise the real LauncherIcon and SerialExecutor with memory-only Android APIs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "tile-app/src/com/ruin/magpie/tile"
FILES = {
    "android/content/ComponentName.java": """package android.content; public class ComponentName { public ComponentName(Context c,String s) {} }""",
    "android/content/Context.java": """package android.content; import android.content.pm.PackageManager; public class Context { public static final int MODE_PRIVATE=0; public final PackageManager pm=new PackageManager(); public final SharedPreferences sp=new SharedPreferences(); public PackageManager getPackageManager(){return pm;} public SharedPreferences getSharedPreferences(String n,int m){return sp;} }""",
    "android/content/SharedPreferences.java": """package android.content; import java.util.HashMap; public class SharedPreferences { private final HashMap<String,Boolean> data=new HashMap<>(); public boolean contains(String k){return data.containsKey(k);} public boolean getBoolean(String k,boolean d){return data.containsKey(k)?data.get(k):d;} public Editor edit(){return new Editor();} public final class Editor { String k; boolean v; public Editor putBoolean(String k,boolean v){this.k=k;this.v=v;return this;} public void apply(){data.put(k,v);} } }""",
    "android/content/pm/PackageManager.java": """package android.content.pm; import android.content.ComponentName; public class PackageManager { public static final int COMPONENT_ENABLED_STATE_DEFAULT=0, COMPONENT_ENABLED_STATE_ENABLED=1, COMPONENT_ENABLED_STATE_DISABLED=2, COMPONENT_ENABLED_STATE_DISABLED_USER=3, DONT_KILL_APP=1; public int state=COMPONENT_ENABLED_STATE_DEFAULT; public int getComponentEnabledSetting(ComponentName n){return state;} public void setComponentEnabledSetting(ComponentName n,int s,int f){state=s;} }""",
    "android/util/Log.java": """package android.util; public class Log { public static int w(String t,String s){return 0;} }""",
    "com/ruin/magpie/tile/Shell.java": """package com.ruin.magpie.tile;
import java.util.ArrayList;
final class Shell {
    interface Callback<T>{ void onResult(T t); }
    static class Result { boolean ok=true; String err=""; }
    static final ArrayList<Runnable> ready=new ArrayList<>();
    static final SerialExecutor ordered=new SerialExecutor(r -> ready.add(r));
    static boolean flag;
    static int completed;
    static void run(String c,Callback<Result> cb){throw new AssertionError("unordered persistence");}
    static void runSerial(final String c,final Callback<Result> cb){
        ordered.execute(() -> {flag=!c.startsWith("rm -f "); completed++; cb.onResult(new Result());});
    }
    // Adversarial backend: execute newest runnable first. A serial executor
    // must expose only one runnable, otherwise this recreates the old race.
    static void completeNewest(){
        if(ready.size()!=1)throw new AssertionError("overlapping side effects="+ready.size());
        ready.remove(ready.size()-1).run();
    }
}""",
    "com/ruin/magpie/tile/LauncherTest.java": """package com.ruin.magpie.tile;
import android.content.Context;
public class LauncherTest {
    public static void main(String[] args){
        Context c=new Context(); String choices=args[0];
        for(int i=0;i<choices.length();i++){
            boolean hidden=choices.charAt(i)=='1';
            if(!LauncherIcon.setHidden(c,hidden))throw new AssertionError("component change failed");
            if(LauncherIcon.isHidden(c)!=hidden)throw new AssertionError("component not immediate");
        }
        while(!Shell.ready.isEmpty())Shell.completeNewest();
        boolean expected=choices.charAt(choices.length()-1)=='1';
        if(LauncherIcon.isHidden(c)!=expected
                || c.sp.getBoolean("launcher_hidden",!expected)!=expected
                || Shell.flag!=expected || Shell.completed!=choices.length())
            throw new AssertionError("component/preferences/module flag diverged");
        System.out.println("all states agree with latest choice; no su or Android state modified");
    }
}""",
}


class LauncherRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ("javac", "java"):
            if shutil.which(tool) is None:
                raise RuntimeError(f"missing required tool: {tool}")
        cls.temp = tempfile.TemporaryDirectory(prefix="magpie-launcher-test.")
        cls.addClassCleanup(cls.temp.cleanup)
        work = Path(cls.temp.name)
        for name, content in FILES.items():
            p = work / "src" / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
        cls.classes = work / "classes"
        cls.classes.mkdir()
        subprocess.run(["javac", "-encoding", "UTF-8", "-d", str(cls.classes),
                        *map(str, (work / "src").rglob("*.java")),
                        str(SRC / "LauncherIcon.java"), str(SRC / "SerialExecutor.java")],
                       check=True, capture_output=True, text=True, timeout=90)

    def run_choices(self, choices):
        result = subprocess.run(["java", "-cp", str(self.classes),
                                 "com.ruin.magpie.tile.LauncherTest", choices],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hide_then_show(self):
        self.run_choices("10")

    def test_show_then_hide(self):
        self.run_choices("01")

    def test_many_rapid_choices(self):
        self.run_choices("101001101010")


if __name__ == "__main__":
    unittest.main()

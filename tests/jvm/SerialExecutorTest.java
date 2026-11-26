package com.ruin.magpie.tile;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.Executor;

public final class SerialExecutorTest {
    private static int passed;
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
        passed++;
        System.out.println("  PASS  " + message);
    }
    private static final class Manual implements Executor {
        final ArrayDeque<Runnable> ready = new ArrayDeque<>();
        @Override public void execute(Runnable r) { ready.add(r); }
        void next() { ready.remove().run(); }
    }
    public static void main(String[] args) {
        Manual backend = new Manual();
        SerialExecutor serial = new SerialExecutor(backend);
        List<String> events = new ArrayList<>();
        serial.execute(() -> events.add("hide"));
        serial.execute(() -> events.add("show"));
        serial.execute(() -> events.add("hide-again"));
        check(backend.ready.size() == 1, "only one persistence command reaches worker pool");
        backend.next();
        check(events.equals(Arrays.asList("hide")), "first submitted side effect runs first");
        check(backend.ready.size() == 1, "next command scheduled only after previous completes");
        backend.next(); backend.next();
        check(events.equals(Arrays.asList("hide", "show", "hide-again")), "rapid icon choices preserve FIFO");
        check(backend.ready.isEmpty(), "no permanent worker or polling task left behind");
        serial.execute(() -> { throw new IllegalStateException("test failure"); });
        serial.execute(() -> events.add("after-failure"));
        try { backend.next(); } catch (IllegalStateException expected) { /* intentional */ }
        check(backend.ready.size() == 1, "exception cannot stall subsequent persistence");
        backend.next();
        check(events.get(events.size() - 1).equals("after-failure"), "queue recovers from failed task");
        boolean threw = false;
        try { serial.execute(null); } catch (NullPointerException expected) { threw = true; }
        check(threw, "null submissions rejected before touching queue");
        System.out.println("SerialExecutorTest: PASS " + passed);
    }
}

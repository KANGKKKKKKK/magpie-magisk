package com.ruin.magpie.tile;

import java.util.ArrayDeque;
import java.util.concurrent.Executor;

/** FIFO for ordered side effects, sharing the existing short-lived worker pool. */
final class SerialExecutor implements Executor {
    private final Executor backend;
    private final ArrayDeque<Runnable> queue = new ArrayDeque<>();
    private Runnable active;

    SerialExecutor(Executor backend) {
        this.backend = backend;
    }

    @Override
    public synchronized void execute(final Runnable command) {
        if (command == null) throw new NullPointerException("command");
        queue.offer(new Runnable() {
            @Override public void run() {
                try {
                    command.run();
                } finally {
                    scheduleNext();
                }
            }
        });
        if (active == null) scheduleNext();
    }

    private synchronized void scheduleNext() {
        active = queue.poll();
        if (active != null) backend.execute(active);
    }
}

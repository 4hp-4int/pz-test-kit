package zombie.network.statistics.counters;

/**
 * Stub for PZ's ObjectPoolCounter (added in 42.20). The real ObjectPool now
 * extends this and calls super(name), which registers a Counter with the
 * PoolStatistic singleton — a chain that touches LuaManager.platform and
 * Prometheus metrics at class-init time. None of that exists (or matters)
 * in the test kit, so the stub just swallows the registration.
 *
 * Without this, StubbingClassLoader synthesizes an empty class with only a
 * no-arg constructor and ObjectPool's super(name) throws NoSuchMethodError
 * from StringLib.&lt;clinit&gt;.
 */
public abstract class ObjectPoolCounter {
    public ObjectPoolCounter(String name) {}

    public abstract int size();
}

/**
	Interruptible Task synchronization facilities

	Copyright: © 2012-2016 RejectedSoftware e.K.
	Authors: Leonid Kramer, Sönke Ludwig, Manuel Frischknecht
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.sync;

import vibe.core.log : logDebugV, logTrace, logInfo;
import vibe.core.task;

import core.atomic;
import core.sync.mutex;
import core.sync.condition;
import eventcore.core;
import std.exception;
import std.stdio;
import std.traits : ReturnType;


enum LockMode {
	lock,
	tryLock,
	defer
}

interface Lockable {
	@safe:
	void lock();
	void unlock();
	bool tryLock();
}

/** RAII lock for the Mutex class.
*/
struct ScopedMutexLock
{
	@disable this(this);
	private {
		Mutex m_mutex;
		bool m_locked;
		LockMode m_mode;
	}

	this(core.sync.mutex.Mutex mutex, LockMode mode = LockMode.lock) {
		assert(mutex !is null);
		m_mutex = mutex;

		final switch (mode) {
			case LockMode.lock: lock(); break;
			case LockMode.tryLock: tryLock(); break;
			case LockMode.defer: break;
		}
	}

	~this()
	{
		if( m_locked )
			m_mutex.unlock();
	}

	@property bool locked() const { return m_locked; }

	void unlock()
	{
		enforce(m_locked);
		m_mutex.unlock();
		m_locked = false;
	}

	bool tryLock()
	{
		enforce(!m_locked);
		return m_locked = m_mutex.tryLock();
	}

	void lock()
	{
		enforce(!m_locked);
		m_locked = true;
		m_mutex.lock();
	}
}


/*
	Only for internal use:
	Ensures that a mutex is locked while executing the given procedure.

	This function works for all kinds of mutexes, in particular for
	$(D core.sync.mutex.Mutex), $(D TaskMutex) and $(D InterruptibleTaskMutex).

	Returns:
		Returns the value returned from $(D PROC), if any.
*/
/// private
ReturnType!PROC performLocked(alias PROC, MUTEX)(MUTEX mutex)
{
	mutex.lock();
	scope (exit) mutex.unlock();
	return PROC();
}

///
unittest {
	int protected_var = 0;
	auto mtx = new TaskMutex;
	mtx.performLocked!({
		protected_var++;
	});
}


/**
	Thread-local semaphore implementation for tasks.

	When the semaphore runs out of concurrent locks, it will suspend. This class
	is used in `vibe.core.connectionpool` to limit the number of concurrent
	connections.
*/
class LocalTaskSemaphore
{
	// requires a queue
	import std.container.binaryheap;
	import std.container.array;
	//import vibe.utils.memory;

	private {
		static struct ThreadWaiter {
			ManualEvent signal;
			ubyte priority;
			uint seq;
		}

		BinaryHeap!(Array!ThreadWaiter, asc) m_waiters;
		uint m_maxLocks;
		uint m_locks;
		uint m_seq;
	}

	this(uint max_locks) 
	{ 
		m_maxLocks = max_locks;
	}

	/// Maximum number of concurrent locks
	@property void maxLocks(uint max_locks) { m_maxLocks = max_locks; }
	/// ditto
	@property uint maxLocks() const { return m_maxLocks; }

	/// Number of concurrent locks still available
	@property uint available() const { return m_maxLocks - m_locks; }

	/** Try to acquire a lock.

		If a lock cannot be acquired immediately, returns `false` and leaves the
		semaphore in its previous state.

		Returns:
			`true` is returned $(I iff) the number of available locks is greater
			than one.
	*/
	bool tryLock()
	{		
		if (available > 0) 
		{
			m_locks++; 
			return true;
		}
		return false;
	}

	/** Acquires a lock.

		Once the limit of concurrent locks is reaced, this method will block
		until the number of locks drops below the limit.
	*/
	void lock(ubyte priority = 0)
	{
		import std.algorithm.comparison : min;

		if (tryLock())
			return;
		
		ThreadWaiter w;
		w.signal = createManualEvent();
		w.priority = priority;
		w.seq = min(0, m_seq - w.priority);
		if (++m_seq == uint.max)
			rewindSeq();
		
		m_waiters.insert(w);
		do w.signal.wait(); while (!tryLock());
		// on resume:
		destroy(w.signal);
	}

	/** Gives up an existing lock.
	*/
	void unlock() 
	{
		m_locks--;
		if (m_waiters.length > 0 && available > 0) {
			ThreadWaiter w = m_waiters.front();
			w.signal.emit(); // resume one
			m_waiters.removeFront();
		}
	}

	// if true, a goes after b. ie. b comes out front()
	/// private
	static bool asc(ref ThreadWaiter a, ref ThreadWaiter b) 
	{
		if (a.seq == b.seq) {
			if (a.priority == b.priority) {
				// resolve using the pointer address
				return (cast(size_t)&a.signal) > (cast(size_t) &b.signal);
			}
			// resolve using priority
			return a.priority < b.priority;
		}
		// resolve using seq number
		return a.seq > b.seq;
	}

	private void rewindSeq()
	{
		Array!ThreadWaiter waiters = m_waiters.release();
		ushort min_seq;
		import std.algorithm : min;
		foreach (ref waiter; waiters[])
			min_seq = min(waiter.seq, min_seq);
		foreach (ref waiter; waiters[])
			waiter.seq -= min_seq;
		m_waiters.assume(waiters);
	}
}


/**
	Mutex implementation for fibers.

	This mutex type can be used in exchange for a core.sync.mutex.Mutex, but
	does not block the event loop when contention happens. Note that this
	mutex does not allow recursive locking.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleTaskMutex) as an alternative that can be
		interrupted.

	See_Also: InterruptibleTaskMutex, RecursiveTaskMutex, core.sync.mutex.Mutex
*/
class TaskMutex : core.sync.mutex.Mutex, Lockable {
	private TaskMutexImpl!false m_impl;

	this(Object o) { m_impl.setup(); super(o); }
	this() { m_impl.setup(); }

	override bool tryLock() nothrow { return m_impl.tryLock(); }
	override void lock() nothrow { m_impl.lock(); }
	override void unlock() nothrow { m_impl.unlock(); }
}

unittest {
	auto mutex = new TaskMutex;

	{
		auto lock = ScopedMutexLock(mutex);
		assert(lock.locked);
		assert(mutex.m_impl.m_locked);

		auto lock2 = ScopedMutexLock(mutex, LockMode.tryLock);
		assert(!lock2.locked);
	}
	assert(!mutex.m_impl.m_locked);

	auto lock = ScopedMutexLock(mutex, LockMode.tryLock);
	assert(lock.locked);
	lock.unlock();
	assert(!lock.locked);

	synchronized(mutex){
		assert(mutex.m_impl.m_locked);
	}
	assert(!mutex.m_impl.m_locked);

	mutex.performLocked!({
		assert(mutex.m_impl.m_locked);
	});
	assert(!mutex.m_impl.m_locked);

	static if (__VERSION__ >= 2067) {
		with(mutex.ScopedMutexLock) {
			assert(mutex.m_impl.m_locked);
		}
	}
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest { // test deferred throwing
	import vibe.core.core;

	auto mutex = new TaskMutex;
	auto t1 = runTask({
		scope (failure) assert(false, "No exception expected in first task!");
		mutex.lock();
		scope (exit) mutex.unlock();
		sleep(20.msecs);
	});

	auto t2 = runTask({
		mutex.lock();
		scope (exit) mutex.unlock();
		try {
			yield();
			assert(false, "Yield is supposed to have thrown an InterruptException.");
		} catch (InterruptException) {
			// as expected!
		} catch (Exception) {
			assert(false, "Only InterruptException supposed to be thrown!");
		}
	});

	runTask({
		// mutex is now locked in first task for 20 ms
		// the second tasks is waiting in lock()
		t2.interrupt();
		t1.join();
		t2.join();
		assert(!mutex.m_impl.m_locked); // ensure that the scope(exit) has been executed
		exitEventLoop();
	});

	runEventLoop();
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!TaskMutex();
}


/**
	Alternative to $(D TaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D TaskMutex), $(D InterruptibleRecursiveTaskMutex)
*/
final class InterruptibleTaskMutex : Lockable {
	private TaskMutexImpl!true m_impl;

	this() { m_impl.setup(); }

	bool tryLock() nothrow { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() nothrow { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!InterruptibleTaskMutex();
}



/**
	Recursive mutex implementation for tasks.

	This mutex type can be used in exchange for a core.sync.mutex.Mutex, but
	does not block the event loop when contention happens.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleRecursiveTaskMutex) as an alternative that can be
		interrupted.

	See_Also: TaskMutex, core.sync.mutex.Mutex
*/
class RecursiveTaskMutex : core.sync.mutex.Mutex, Lockable {
	private RecursiveTaskMutexImpl!false m_impl;

	this(Object o) { m_impl.setup(); super(o); }
	this() { m_impl.setup(); }

	override bool tryLock() { return m_impl.tryLock(); }
	override void lock() { m_impl.lock(); }
	override void unlock() { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!RecursiveTaskMutex();
}


/**
	Alternative to $(D RecursiveTaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D RecursiveTaskMutex), $(D InterruptibleTaskMutex)
*/
final class InterruptibleRecursiveTaskMutex : Lockable {
	private RecursiveTaskMutexImpl!true m_impl;

	this() { m_impl.setup(); }

	bool tryLock() { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!InterruptibleRecursiveTaskMutex();
}


private void runMutexUnitTests(M)()
{
	import vibe.core.core;

	auto m = new M;
	Task t1, t2;
	void runContendedTasks(bool interrupt_t1, bool interrupt_t2) {
		assert(!m.m_impl.m_locked);

		// t1 starts first and acquires the mutex for 20 ms
		// t2 starts second and has to wait in m.lock()
		t1 = runTask({
			assert(!m.m_impl.m_locked);
			m.lock();
			assert(m.m_impl.m_locked);
			if (interrupt_t1) assertThrown!InterruptException(sleep(100.msecs));
			else assertNotThrown(sleep(20.msecs));
			m.unlock();
		});
		t2 = runTask({
			assert(!m.tryLock());
			if (interrupt_t2) {
				try m.lock();
				catch (InterruptException) return;
				try yield(); // rethrows any deferred exceptions
				catch (InterruptException) {
					m.unlock();
					return;
				}
				assert(false, "Supposed to have thrown an InterruptException.");
			} else assertNotThrown(m.lock());
			assert(m.m_impl.m_locked);
			sleep(20.msecs);
			m.unlock();
			assert(!m.m_impl.m_locked);
		});
	}

	// basic lock test
	m.performLocked!({
		assert(m.m_impl.m_locked);
	});
	assert(!m.m_impl.m_locked);

	// basic contention test
	runContendedTasks(false, false);
	runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t1.join();
		assert(!t1.running && t2.running);
		yield(); // give t2 a chance to take the lock
		assert(m.m_impl.m_locked);
		t2.join();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!m.m_impl.m_locked);

	// interruption test #1
	runContendedTasks(true, false);
	runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t1.interrupt();
		t1.join();
		assert(!t1.running && t2.running);
		yield(); // give t2 a chance to take the lock
		assert(m.m_impl.m_locked);
		t2.join();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!m.m_impl.m_locked);

	// interruption test #2
	runContendedTasks(false, true);
	runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t2.interrupt();
		t2.join();
		assert(!t2.running);
		static if (is(M == InterruptibleTaskMutex) || is (M == InterruptibleRecursiveTaskMutex))
			assert(t1.running && m.m_impl.m_locked);
		t1.join();
		assert(!t1.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!m.m_impl.m_locked);
}


/**
	Event loop based condition variable or "event" implementation.

	This class can be used in exchange for a $(D core.sync.condition.Condition)
	to avoid blocking the event loop when waiting.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields to the event loop.

		Use $(D InterruptibleTaskCondition) as an alternative that can be
		interrupted.

		Note that it is generally not safe to use a `TaskCondition` together with an
		interruptible mutex type.

	See_Also: InterruptibleTaskCondition
*/
class TaskCondition : core.sync.condition.Condition {
	private TaskConditionImpl!(false, Mutex) m_impl;

	this(core.sync.mutex.Mutex mtx) {
		m_impl.setup(mtx);
		super(mtx);
	}
	override @property Mutex mutex() { return m_impl.mutex; }
	override void wait() { m_impl.wait(); }
	override bool wait(Duration timeout) { return m_impl.wait(timeout); }
	override void notify() { m_impl.notify(); }
	override void notifyAll() { m_impl.notifyAll(); }
}

/** This example shows the typical usage pattern using a `while` loop to make
	sure that the final condition is reached.
*/
unittest {
	import vibe.core.core;
	import vibe.core.log;

	__gshared Mutex mutex;
	__gshared TaskCondition condition;
	__gshared int workers_still_running = 0;

	// setup the task condition
	mutex = new Mutex;
	condition = new TaskCondition(mutex);

	logDebug("SETTING UP TASKS");

	// start up the workers and count how many are running
	foreach (i; 0 .. 4) {
		workers_still_running++;
		runWorkerTask({
			// simulate some work
			sleep(100.msecs);

			// notify the waiter that we're finished
			synchronized (mutex) {
				workers_still_running--;
			logDebug("DECREMENT %s", workers_still_running);
			}
			logDebug("NOTIFY");
			condition.notify();
		});
	}

	logDebug("STARTING WAIT LOOP");

	// wait until all tasks have decremented the counter back to zero
	synchronized (mutex) {
		while (workers_still_running > 0) {
			logDebug("STILL running %s", workers_still_running);
			condition.wait();
		}
	}
}


/**
	Alternative to `TaskCondition` that supports interruption.

	This class supports the use of `vibe.core.task.Task.interrupt()` while
	waiting in the `wait()` method.

	See `TaskCondition` for an example.

	Notice:
		Note that it is generally not safe to use an
		`InterruptibleTaskCondition` together with an interruptible mutex type.

	See_Also: `TaskCondition`
*/
final class InterruptibleTaskCondition {
	private TaskConditionImpl!(true, Lockable) m_impl;

	this(core.sync.mutex.Mutex mtx) { m_impl.setup(mtx); }
	this(Lockable mtx) { m_impl.setup(mtx); }

	@property Lockable mutex() { return m_impl.mutex; }
	void wait() { m_impl.wait(); }
	bool wait(Duration timeout) { return m_impl.wait(timeout); }
	void notify() { m_impl.notify(); }
	void notifyAll() { m_impl.notifyAll(); }
}


/** Creates a new signal that can be shared between fibers.
*/
ManualEvent createManualEvent()
{
	return ManualEvent.init;
}
/// ditto
shared(ManualEvent) createSharedManualEvent()
{
	return shared(ManualEvent).init;
}

/** A manually triggered cross-task event.

	Note: the ownership can be shared between multiple fibers and threads.
*/
struct ManualEvent {
	import core.thread : Thread;
	import vibe.internal.async : Waitable, asyncAwait, asyncAwaitUninterruptible, asyncAwaitAny;

	@safe:

	private {
		static struct ThreadWaiter {
			ThreadWaiter* next;
			EventID event;
			EventDriver driver;
			Thread thread;
			StackSList!LocalWaiter tasks;
		}
		static struct LocalWaiter {
			LocalWaiter* next;
			Task task;
			void delegate() @safe nothrow notifier;
			bool cancelled = false;

			void wait(void delegate() @safe nothrow del) @safe nothrow {
				assert(notifier is null, "Local waiter is used twice!");
				notifier = del;
			}
			void cancel() @safe nothrow { cancelled = true; notifier = null; }
		}
		int m_emitCount;
		ThreadWaiter* m_waiters;
	}

	// thread destructor in vibe.core.core will decrement the ref. count
	package static EventID ms_threadEvent;

	enum EmitMode {
		single,
		all
	}

	//@disable this(this);

	deprecated("ManualEvent is always non-null!")
	bool opCast() const nothrow { return true; }
	deprecated("ManualEvent is always non-null!")
	bool opCast() const shared nothrow { return true; }

	/// A counter that is increased with every emit() call
	int emitCount() const nothrow { return m_emitCount; }
	/// ditto
	int emitCount() const shared nothrow @trusted { return atomicLoad(m_emitCount); }

	/// Emits the signal, waking up all owners of the signal.
	int emit(EmitMode mode = EmitMode.all)
	shared nothrow @trusted {
		import core.atomic : atomicOp, cas;

		logTrace("emit shared");

		auto ec = atomicOp!"+="(m_emitCount, 1);
		auto thisthr = Thread.getThis();

		final switch (mode) {
			case EmitMode.all:
				// FIXME: would be nice to have atomicSwap instead
				auto w = cast(ThreadWaiter*)atomicLoad(m_waiters);
				if (w !is null && !cas(&m_waiters, cast(shared(ThreadWaiter)*)w, cast(shared(ThreadWaiter)*)null)) {
					logTrace("Another thread emitted concurrently - returning.");
					return ec;
				}
				while (w !is null) {
					// Note: emitForThisThread can result in w getting deallocated at any
					//       time, so we need to copy any fields first
					auto wnext = w.next;
					atomicStore((cast(shared)w).next, null);
					assert(wnext !is w, "Same waiter enqueued twice!?");
					if (w.driver is eventDriver) {
						logTrace("Same thread emit (%s/%s)", cast(void*)w, cast(void*)w.tasks.first);
						emitForThisThread(w.tasks.m_first, mode);
					} else {
						logTrace("Foreign thread \"%s\" notify: %s", w.thread.name, w.event);
						auto drv = w.driver;
						auto evt = w.event;
						if (evt != EventID.init)
							(cast(shared)drv.events).trigger(evt, true);
					}
					w = wnext;
				}
				break;
			case EmitMode.single:
				assert(false);
		}

		logTrace("emit shared done");

		return ec;
	}
	/// ditto
	int emit(EmitMode mode = EmitMode.all)
	nothrow {
		auto ec = m_emitCount++;

		logTrace("unshared emit");

		final switch (mode) {
			case EmitMode.all:
				auto w = m_waiters;
				m_waiters = null;
				if (w !is null) {
					assert(w.driver is eventDriver, "Unshared ManualEvent has waiters in foreign thread!");
					assert(w.next is null, "Unshared ManualEvent has waiters in multiple threads!");
					emitForThisThread(w.tasks.m_first, EmitMode.all);
				}
				break;
			case EmitMode.single:
				assert(false);
		}
		return ec;
	}

	/** Acquires ownership and waits until the signal is emitted.

		Note that in order not to miss any emits it is necessary to use the
		overload taking an integer.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait() { return wait(this.emitCount); }
	/// ditto
	int wait() shared { return wait(this.emitCount); }

	/** Acquires ownership and waits until the emit count differs from the
		given one or until a timeout is reached.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait(int emit_count) { return doWait!true(Duration.max, emit_count); }
	/// ditto
	int wait(int emit_count) shared { return doWaitShared!true(Duration.max, emit_count); }
	/// ditto
	int wait(Duration timeout, int emit_count) { return doWait!true(timeout, emit_count); }
	/// ditto
	int wait(Duration timeout, int emit_count) shared { return doWaitShared!true(timeout, emit_count); }
	
	/** Same as $(D wait), but defers throwing any $(D InterruptException).

		This method is annotated $(D nothrow) at the expense that it cannot be
		interrupted.
	*/
	int waitUninterruptible() nothrow { return waitUninterruptible(this.emitCount); }
	///
	int waitUninterruptible() shared nothrow { return waitUninterruptible(this.emitCount); }
	/// ditto
	int waitUninterruptible(int emit_count) nothrow { return doWait!false(Duration.max, emit_count); }
	/// ditto
	int waitUninterruptible(int emit_count) shared nothrow { return doWaitShared!false(Duration.max, emit_count); }
	/// ditto
	int waitUninterruptible(Duration timeout, int emit_count) nothrow { return doWait!false(timeout, emit_count); }
	/// ditto
	int waitUninterruptible(Duration timeout, int emit_count) shared nothrow { return doWaitShared!false(timeout, emit_count); }

	private int doWait(bool interruptible)(Duration timeout, int emit_count)
	{
		int ec = this.emitCount;
		while (ec <= emit_count) {
			ThreadWaiter w;
			LocalWaiter tw;
			() @trusted { acquireWaiter(&w, &tw); } ();

			Waitable!(
				cb => tw.wait(cb),
				cb => tw.cancel()
			) waitable;
			asyncAwaitAny!interruptible(timeout, waitable);
			ec = this.emitCount;
		}
		return ec;
	}

	private int doWaitShared(bool interruptible)(Duration timeout, int emit_count)
	shared {
		int ec = this.emitCount;
		while (ec <= emit_count) {
			shared(ThreadWaiter) w;
			LocalWaiter tw;
			() @trusted { acquireWaiter(&w, &tw); } ();
			() @trusted { logDebugV("Acquired waiter %s %s -> %s", cast(void*)m_waiters, cast(void*)&w, cast(void*)w.next); } ();

			if (tw.next) {
				// if we are not the first waiter for this thread,
				// wait for getting resumed by emitForThisThread
				Waitable!(
					cb => tw.wait(cb),
					cb => tw.cancel()
				) waitable;
				asyncAwaitAny!interruptible(timeout, waitable);
			} else {
				again:
				// if we are the first waiter for this thread,
				// wait for the thread event to get emitted
				Waitable!(
					cb => eventDriver.events.wait(ms_threadEvent, cb),
					cb => eventDriver.events.cancelWait(ms_threadEvent, cb),
					EventID
				) eventwaiter;
				Waitable!(
					cb => tw.wait(cb),
					cb => tw.cancel()
				) localwaiter;
				logDebugV("Wait on event %s", ms_threadEvent);
				asyncAwaitAny!interruptible(timeout, eventwaiter, localwaiter);

				if (!eventwaiter.cancelled) {
					if (() @trusted { return atomicLoad(w.next); } () is null)
						emitForThisThread(() @trusted { return cast(LocalWaiter*)w.tasks.m_first; } (), EmitMode.all); // FIXME: use proper emit mode
					else goto again;
				} else if (localwaiter.cancelled) break; // timeout
			}

			() @trusted {
				assert(atomicLoad(w.next) is null && atomicLoad(m_waiters) !is &w,
					"Waiter did not get removed from waiter queue.");
			}();

			ec = this.emitCount;
		}
		return ec;
	}

	private static bool emitForThisThread(LocalWaiter* waiters, EmitMode mode)
	nothrow {
		if (!waiters) return false;

		logTrace("emitForThisThread");

		final switch (mode) {
			case EmitMode.all:
				while (waiters) {
					auto wnext = waiters.next;
					assert(wnext !is waiters);
					if (waiters.notifier !is null) {
						logTrace("notify task %s %s %s", cast(void*)waiters, cast(void*)waiters.notifier.funcptr, waiters.notifier.ptr);
						waiters.notifier();
						waiters.notifier = null;
					} else logTrace("notify callback is null");
					waiters = wnext;
				}
				break;
			case EmitMode.single:
				assert(false, "TODO!");
		}

		return true;
	}

	private void acquireWaiter(ThreadWaiter* w, LocalWaiter* tw)
	nothrow {
		// FIXME: this doesn't work! if task a starts to wait, task b afterwards, and then a finishes its wait before b, the ThreadWaiter will be dangling
		tw.task = Task.getThis();

		if (m_waiters) {
			m_waiters.tasks.add(tw);
		} else {
			m_waiters = w;
		}
	}

	private void acquireWaiter(shared(ThreadWaiter)* w, LocalWaiter* tw)
	nothrow shared {
		tw.task = Task.getThis();

		if (ms_threadEvent == EventID.init)
			ms_threadEvent = eventDriver.events.create();

		auto sdriver = () @trusted { return cast(shared)eventDriver; } ();

		shared(ThreadWaiter)* pw = () @trusted { return atomicLoad(m_waiters); } ();
		assert(pw !is w, "Waiter is already registered!");
		while (pw !is null) {
			if (pw.driver is sdriver)
				break;
			pw = () @trusted { return atomicLoad(pw.next); } ();
		}

		if (!pw) {
			pw = w;
			shared(ThreadWaiter)* wn;
			do {
				wn = () @trusted { return atomicLoad(m_waiters); } ();
				w.next = wn;
				w.event = ms_threadEvent;
				w.driver = sdriver;
				w.thread = () @trusted { return cast(shared)Thread.getThis(); } ();
			} while (!() @trusted { return cas(&m_waiters, wn, w); } ());
		}

		() @trusted { return cast(ThreadWaiter*)pw; } ().tasks.add(tw);
	}
}


private struct StackSList(T)
{
	import core.atomic : cas;

	private T* m_first;

	@property T* first() { return m_first; }
	@property shared(T)* first() shared { return atomicLoad(m_first); }

	void add(shared(T)* elem)
	shared {
		do elem.next = atomicLoad(m_first);
		while (cas(&m_first, elem.next, elem));
	}

	void remove(shared(T)* elem)
	shared {
		while (true) {
			shared(T)* w = atomicLoad(m_first), wp;
			while (w !is elem) {
				wp = w;
				w = atomicLoad(w.next);
			}
			if (wp !is null) {
				if (cas(&wp.next, w, w.next))
					break;
			} else {
				if (cas(&m_first, w, w.next))
					break;
			}
		}
	}

	bool empty() const { return m_first is null; }

	void add(T* elem)
	{
		elem.next = m_first;
		m_first = elem;
	}

	void remove(T* elem)
	{
		T* w = m_first, wp;
		while (w !is elem) {
			assert(w !is null);
			wp = w;
			w = w.next;
		}
		if (wp) wp.next = w.next;
		else m_first = w.next;
	}
}

private struct TaskMutexImpl(bool INTERRUPTIBLE) {
	private {
		shared(bool) m_locked = false;
		shared(uint) m_waiters = 0;
		shared(ManualEvent) m_signal;
		debug Task m_owner;
	}

	void setup()
	{
		m_signal = createSharedManualEvent();
	}


	@trusted bool tryLock()
	{
		if (cas(&m_locked, false, true)) {
			debug m_owner = Task.getThis();
			debug(VibeMutexLog) logTrace("mutex %s lock %s", cast(void*)&this, atomicLoad(m_waiters));
			return true;
		}
		return false;
	}

	@trusted void lock()
	{
		if (tryLock()) return;
		debug assert(m_owner == Task() || m_owner != Task.getThis(), "Recursive mutex lock.");
		atomicOp!"+="(m_waiters, 1);
		debug(VibeMutexLog) logTrace("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters));
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		while (!tryLock()) {
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(ecnt);
			else ecnt = m_signal.waitUninterruptible(ecnt);
		}
	}

	@trusted void unlock()
	{
		assert(m_locked);
		debug {
			assert(m_owner == Task.getThis());
			m_owner = Task();
		}
		atomicStore!(MemoryOrder.rel)(m_locked, false);
		debug(VibeMutexLog) logTrace("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters));
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct RecursiveTaskMutexImpl(bool INTERRUPTIBLE) {
	import std.stdio;
	private {
		core.sync.mutex.Mutex m_mutex;
		Task m_owner;
		size_t m_recCount = 0;
		shared(uint) m_waiters = 0;
		shared(ManualEvent) m_signal;
		@property bool m_locked() const { return m_recCount > 0; }
	}

	void setup()
	{
		m_signal = createSharedManualEvent();
		m_mutex = new core.sync.mutex.Mutex;
	}

	@trusted bool tryLock()
	{
		auto self = Task.getThis();
		return m_mutex.performLocked!({
			if (!m_owner) {
				assert(m_recCount == 0);
				m_recCount = 1;
				m_owner = self;
				return true;
			} else if (m_owner == self) {
				m_recCount++;
				return true;
			}
			return false;
		});
	}

	@trusted void lock()
	{
		if (tryLock()) return;
		atomicOp!"+="(m_waiters, 1);
		debug(VibeMutexLog) logTrace("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters));
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		while (!tryLock()) {
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(ecnt);
			else ecnt = m_signal.waitUninterruptible(ecnt);
		}
	}

	@trusted void unlock()
	{
		auto self = Task.getThis();
		m_mutex.performLocked!({
			assert(m_owner == self);
			assert(m_recCount > 0);
			m_recCount--;
			if (m_recCount == 0) {
				m_owner = Task.init;
			}
		});
		debug(VibeMutexLog) logTrace("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters));
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct TaskConditionImpl(bool INTERRUPTIBLE, LOCKABLE) {
	private {
		LOCKABLE m_mutex;

		shared(ManualEvent) m_signal;
	}

	static if (is(LOCKABLE == Lockable)) {
		final class MutexWrapper : Lockable {
			private core.sync.mutex.Mutex m_mutex;
			this(core.sync.mutex.Mutex mtx) { m_mutex = mtx; }
			@trusted void lock() { m_mutex.lock(); }
			@trusted void unlock() { m_mutex.unlock(); }
			@trusted bool tryLock() { return m_mutex.tryLock(); }
		}

		void setup(core.sync.mutex.Mutex mtx)
		{
			setup(new MutexWrapper(mtx));
		}
	}

	void setup(LOCKABLE mtx)
	{
		m_mutex = mtx;
		m_signal = createSharedManualEvent();
	}

	@property LOCKABLE mutex() { return m_mutex; }

	@trusted void wait()
	{
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;
		m_mutex.unlock();
		scope(exit) m_mutex.lock();
		static if (INTERRUPTIBLE) m_signal.wait(refcount);
		else m_signal.waitUninterruptible(refcount);
	}

	@trusted bool wait(Duration timeout)
	{
		assert(!timeout.isNegative());
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;
		m_mutex.unlock();
		scope(exit) m_mutex.lock();

		static if (INTERRUPTIBLE) return m_signal.wait(timeout, refcount) != refcount;
		else return m_signal.waitUninterruptible(timeout, refcount) != refcount;
	}

	@trusted void notify()
	{
		m_signal.emit();
	}

	@trusted void notifyAll()
	{
		m_signal.emit();
	}
}

/** Contains the shared state of a $(D TaskReadWriteMutex).
 *
 *  Since a $(D TaskReadWriteMutex) consists of two actual Mutex
 *  objects that rely on common memory, this class implements
 *  the actual functionality of their method calls.
 *
 *  The method implementations are based on two static parameters
 *  ($(D INTERRUPTIBLE) and $(D INTENT)), which are configured through 
 *  template arguments:
 *
 *  - $(D INTERRUPTIBLE) determines whether the mutex implementation
 *    are interruptible by vibe.d's $(D vibe.core.task.Task.interrupt())
 *    method or not.
 *
 *  - $(D INTENT) describes the intent, with which a locking operation is
 *    performed (i.e. $(D READ_ONLY) or $(D READ_WRITE)). RO locking allows for
 *    multiple Tasks holding the mutex, whereas RW locking will cause
 *    a "bottleneck" so that only one Task can write to the protected
 *    data at once.
 */
private struct ReadWriteMutexState(bool INTERRUPTIBLE)
{
    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is 
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the 
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    enum Policy : int
    {
        /** Readers are prioritized, writers may be starved as a result. */
        PREFER_READERS = 0,
        /** Writers are prioritized, readers may be starved as a result. */
        PREFER_WRITERS
    }
    
    /** The intent with which a locking operation is performed.
     *
     *  Since both locks share the same underlying algorithms, the actual
     *  intent with which a lock operation is performed (i.e read/write)
     *  are passed as a template parameter to each method.
     */
    enum LockingIntent : bool
    {
        /** Perform a read lock/unlock operation. Multiple reading locks can be
         *  active at a time. */
        READ_ONLY = 0,
        /** Perform a write lock/unlock operation. Only a single writer can
         *  hold a lock at any given time. */
        READ_WRITE = 1
    }
    
    private {
        //Queue counters
        /** The number of reading tasks waiting for the lock to become available. */
        shared(uint)  m_waitingForReadLock = 0;
        /** The number of writing tasks waiting for the lock to become available. */
        shared(uint)  m_waitingForWriteLock = 0;
        
        //Lock counters
        /** The number of reading tasks that currently hold the lock. */
        uint  m_activeReadLocks = 0;
        /** The number of writing tasks that currently hold the lock (binary). */
        ubyte m_activeWriteLocks = 0;
        
        /** The policy determining the lock's behavior. */
        Policy m_policy;
        
        //Queue Events
        /** The event used to wake reading tasks waiting for the lock while it is blocked. */
        shared(ManualEvent) m_readyForReadLock;
        /** The event used to wake writing tasks waiting for the lock while it is blocked. */
        shared(ManualEvent) m_readyForWriteLock;

        /** The underlying mutex that gates the access to the shared state. */
        Mutex m_counterMutex;
    }
    
    this(Policy policy)
    {
        m_policy = policy;
        m_counterMutex = new Mutex();
        m_readyForReadLock  = createSharedManualEvent();
        m_readyForWriteLock = createSharedManualEvent();
    }

    @disable this(this);
    
    /** The policy with which the lock has been created. */
    @property policy() const { return m_policy; }
    
    version(RWMutexPrint)
    {
        /** Print out debug information during lock operations. */
        void printInfo(string OP, LockingIntent INTENT)() nothrow
        {
        	import std.string;
            try
            {
                import std.stdio;
                writefln("RWMutex: %s (%s), active: RO: %d, RW: %d; waiting: RO: %d, RW: %d", 
                    OP.leftJustify(10,' '), 
                    INTENT == LockingIntent.READ_ONLY ? "RO" : "RW", 
                    m_activeReadLocks,    m_activeWriteLocks, 
                    m_waitingForReadLock, m_waitingForWriteLock
                    );
            }
            catch (Throwable t){}
        }
    }
    
    /** An internal shortcut method to determine the queue event for a given intent. */
    @property ref auto queueEvent(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_readyForReadLock;
        else
            return m_readyForWriteLock;
    }
    
    /** An internal shortcut method to determine the queue counter for a given intent. */
    @property ref auto queueCounter(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_waitingForReadLock;
        else
            return m_waitingForWriteLock;
    }
    
    /** An internal shortcut method to determine the current emitCount of the queue counter for a given intent. */
    int emitCount(LockingIntent INTENT)()
    {
        return queueEvent!INTENT.emitCount();
    }
    
    /** An internal shortcut method to determine the active counter for a given intent. */
    @property ref auto activeCounter(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_activeReadLocks;
        else
            return m_activeWriteLocks;
    }
    
    /** An internal shortcut method to wait for the queue event for a given intent. 
     *
     *  This method is used during the `lock()` operation, after a
     *  `tryLock()` operation has been unsuccessfully finished.
     *  The active fiber will yield and be suspended until the queue event
     *  for the given intent will be fired.
     */
    int wait(LockingIntent INTENT)(int count)
    {
        static if (INTERRUPTIBLE)
            return queueEvent!INTENT.wait(count);
        else
            return queueEvent!INTENT.waitUninterruptible(count);
    }
    
    /** An internal shortcut method to notify tasks waiting for the lock to become available again. 
     *
     *  This method is called whenever the number of owners of the mutex hits
     *  zero; this is basically the counterpart to `wait()`.
     *  It wakes any Task currently waiting for the mutex to be released.
     */
    @trusted void notify(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
        { //If the last reader unlocks the mutex, notify all waiting writers
            if (atomicLoad(m_waitingForWriteLock) > 0)
                m_readyForWriteLock.emit();
        }
        else
        { //If a writer unlocks the mutex, notify both readers and writers
            if (atomicLoad(m_waitingForReadLock) > 0)
                m_readyForReadLock.emit();
            
            if (atomicLoad(m_waitingForWriteLock) > 0)
                m_readyForWriteLock.emit();
        }
    }
    
    /** An internal method that performs the acquisition attempt in different variations.
     *
     *  Since both locks rely on a common TaskMutex object which gates the access
     *  to their common data acquisition attempts for this lock are more complex
     *  than for simple mutex variants. This method will thus be performing the
     *  `tryLock()` operation in two variations, depending on the callee:
     *
     *  If called from the outside ($(D WAIT_FOR_BLOCKING_MUTEX) = false), the method 
     *  will instantly fail if the underlying mutex is locked (i.e. during another 
     *  `tryLock()` or `unlock()` operation), in order to guarantee the fastest 
     *  possible locking attempt.
     *
     *  If used internally by the `lock()` method ($(D WAIT_FOR_BLOCKING_MUTEX) = true), 
     *  the operation will wait for the mutex to be available before deciding if
     *  the lock can be acquired, since the attempt would anyway be repeated until
     *  it succeeds. This will prevent frequent retries under heavy loads and thus 
     *  should ensure better performance.
     */
    @trusted bool tryLock(LockingIntent INTENT, bool WAIT_FOR_BLOCKING_MUTEX)()
    {
        //Log a debug statement for the attempt
        version(RWMutexPrint)
            printInfo!("tryLock",INTENT)();
        
        //Try to acquire the lock
        static if (!WAIT_FOR_BLOCKING_MUTEX)
        {
            if (!m_counterMutex.tryLock())
                return false;
        }
        else
            m_counterMutex.lock();
        
        scope(exit)
            m_counterMutex.unlock();
        
        //Log a debug statement for the attempt
        version(RWMutexPrint)
            printInfo!("checkCtrs",INTENT)();
        
        //Check if there's already an active writer
        if (m_activeWriteLocks > 0)
            return false;
        
        //If writers are preferred over readers, check whether there
        //currently is a writer in the waiting queue and abort if
        //that's the case.
        static if (INTENT == LockingIntent.READ_ONLY)
            if (m_policy.PREFER_WRITERS && m_waitingForWriteLock > 0)
                return false;
        
        //If we are locking the mutex for writing, make sure that
        //there's no reader active.
        static if (INTENT == LockingIntent.READ_WRITE)
            if (m_activeReadLocks > 0)
                return false;
        
        //We can successfully acquire the lock!
        //Log a debug statement for the success.
        version(RWMutexPrint)
            printInfo!("lock",INTENT)();
        
        //Increase the according counter 
        //(number of active readers/writers)
        //and return a success code.
        activeCounter!INTENT += 1;
        return true;
    }
    
    /** Attempt to acquire the lock for a given intent.
     *
     *  Returns:
     *      `true`, if the lock was successfully acquired;
     *      `false` otherwise.
     */
    @trusted bool tryLock(LockingIntent INTENT)()
    {
        //Try to lock this mutex without waiting for the underlying
        //TaskMutex - fail if it is already blocked.
        return tryLock!(INTENT,false)();
    }
    
    /** Acquire the lock for the given intent; yield and suspend until the lock has been acquired. */
    @trusted void lock(LockingIntent INTENT)()
    {
        //Prepare a waiting action before the first
        //`tryLock()` call in order to avoid a race
        //condition that could lead to the queue notification
        //not being fired.
        auto count = emitCount!INTENT;
        atomicOp!"+="(queueCounter!INTENT,1);
        scope(exit)
            atomicOp!"-="(queueCounter!INTENT,1);
        
        //Try to lock the mutex
        auto locked = tryLock!(INTENT,true)();
        if (locked)
            return;
        
        //Retry until we successfully acquired the lock
        while(!locked)
        {
            version(RWMutexPrint)
                printInfo!("wait",INTENT)();
            
            count  = wait!INTENT(count);
            locked = tryLock!(INTENT,true)();
        }
    }
    
    /** Unlock the mutex after a successful acquisition. */
    @trusted void unlock(LockingIntent INTENT)()
    {
        version(RWMutexPrint)
            printInfo!("unlock",INTENT)();
        
        debug assert(activeCounter!INTENT > 0);

        synchronized(m_counterMutex)
        {
            //Decrement the counter of active lock holders.
            //If the counter hits zero, notify waiting Tasks
            activeCounter!INTENT -= 1;
            if (activeCounter!INTENT == 0)
            {
                version(RWMutexPrint)
                    printInfo!("notify",INTENT)();
                
                notify!INTENT();
            }
        }
    }
}

/** A ReadWriteMutex implementation for fibers.
 *
 *  This mutex can be used in exchange for a $(D core.sync.mutex.ReadWriteMutex),
 *  but does not block the event loop in contention situations. The `reader` and `writer`
 *  members are used for locking. Locking the `reader` mutex allows access to multiple 
 *  readers at once, while the `writer` mutex only allows a single writer to lock it at
 *  any given time. Locks on `reader` and `writer` are mutually exclusive (i.e. whenever a 
 *  writer is active, no readers can be active at the same time, and vice versa).
 * 
 *  Notice:
 *      Mutexes implemented by this class cannot be interrupted
 *      using $(D vibe.core.task.Task.interrupt()). The corresponding
 *      InterruptException will be deferred until the next blocking
 *      operation yields the event loop.
 * 
 *      Use $(D InterruptibleTaskReadWriteMutex) as an alternative that can be
 *      interrupted.
 * 
 *  cf. $(D core.sync.mutex.ReadWriteMutex)
 */
class TaskReadWriteMutex
{
    private {
        alias State = ReadWriteMutexState!false;
        alias LockingIntent = State.LockingIntent;
        alias READ_ONLY  = LockingIntent.READ_ONLY;
        alias READ_WRITE = LockingIntent.READ_WRITE;
        
        /** The shared state used by the reader and writer mutexes. */
        State m_state;
    }
    
    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is 
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the 
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    alias Policy = State.Policy;
    
    /** A common baseclass for both of the provided mutexes.
     *
     *  The intent for the according mutex is specified through the 
     *  $(D INTENT) template argument, which determines if a mutex is 
     *  used for read or write locking.
     */
    final class Mutex(LockingIntent INTENT): core.sync.mutex.Mutex, Lockable
    {
        /** Try to lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override bool tryLock() { return m_state.tryLock!INTENT(); }
        /** Lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void lock()    { m_state.lock!INTENT(); }
        /** Unlock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void unlock()  { m_state.unlock!INTENT(); }
    }
    alias Reader = Mutex!READ_ONLY;
    alias Writer = Mutex!READ_WRITE;
    
    Reader reader;
    Writer writer;
    
    this(Policy policy = Policy.PREFER_WRITERS)
    {
        m_state = State(policy);
        reader = new Reader();
        writer = new Writer();
    }
    
    /** The policy with which the lock has been created. */
    @property Policy policy() const { return m_state.policy; }
}

/** Alternative to $(D TaskReadWriteMutex) that supports interruption.
 *
 *  This class supports the use of $(D vibe.core.task.Task.interrupt()) while
 *  waiting in the `lock()` method.
 * 
 *  cf. $(D core.sync.mutex.ReadWriteMutex)
 */
class InterruptibleTaskReadWriteMutex
{
    private {
        alias State = ReadWriteMutexState!true;
        alias LockingIntent = State.LockingIntent;
        alias READ_ONLY  = LockingIntent.READ_ONLY;
        alias READ_WRITE = LockingIntent.READ_WRITE;
        
        /** The shared state used by the reader and writer mutexes. */
        State m_state;
    }
    
    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is 
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the 
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    alias Policy = State.Policy;
    
    /** A common baseclass for both of the provided mutexes.
     *
     *  The intent for the according mutex is specified through the 
     *  $(D INTENT) template argument, which determines if a mutex is 
     *  used for read or write locking.
     * 
     */
    final class Mutex(LockingIntent INTENT): core.sync.mutex.Mutex, Lockable
    {
        /** Try to lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override bool tryLock() { return m_state.tryLock!INTENT(); }
        /** Lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void lock()    { m_state.lock!INTENT(); }
        /** Unlock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void unlock()  { m_state.unlock!INTENT(); }
    }
    alias Reader = Mutex!READ_ONLY;
    alias Writer = Mutex!READ_WRITE;
    
    Reader reader;
    Writer writer;
    
    this(Policy policy = Policy.PREFER_WRITERS)
    {
        m_state = State(policy);
        reader = new Reader();
        writer = new Writer();
    }
    
    /** The policy with which the lock has been created. */
    @property Policy policy() const { return m_state.policy; }
}
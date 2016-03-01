/**
	Contains interfaces and enums for evented I/O drivers.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.task;

import vibe.core.sync;
import vibe.internal.array : FixedRingBuffer;

import core.thread;
import std.exception;
import std.traits;
import std.typecons;
import std.variant;


/** Represents a single task as started using vibe.core.runTask.

	Note that the Task type is considered weakly isolated and thus can be
	passed between threads using vibe.core.concurrency.send or by passing
	it as a parameter to vibe.core.core.runWorkerTask.
*/
struct Task {
	private {
		shared(TaskFiber) m_fiber;
		size_t m_taskCounter;
		import std.concurrency : ThreadInfo, Tid;
		static ThreadInfo s_tidInfo;
	}

	private this(TaskFiber fiber, size_t task_counter)
	@safe nothrow {
		() @trusted { m_fiber = cast(shared)fiber; } ();
		m_taskCounter = task_counter;
	}

	this(in Task other) nothrow { m_fiber = cast(shared(TaskFiber))other.m_fiber; m_taskCounter = other.m_taskCounter; }

	/** Returns the Task instance belonging to the calling task.
	*/
	static Task getThis() nothrow @safe
	{
		// In 2067, synchronized statements where annotated nothrow.
		// DMD#4115, Druntime#1013, Druntime#1021, Phobos#2704
		// However, they were "logically" nothrow before.
		static if (__VERSION__ <= 2066)
			scope (failure) assert(0, "Internal error: function should be nothrow");

		auto fiber = () @trusted { return Fiber.getThis(); } ();
		if (!fiber) return Task.init;
		auto tfiber = cast(TaskFiber)fiber;
		assert(tfiber !is null, "Invalid or null fiber used to construct Task handle.");
		if (!tfiber.m_running) return Task.init;
		return () @trusted { return Task(tfiber, tfiber.m_taskCounter); } ();
	}

	nothrow {
		@property inout(TaskFiber) fiber() inout @trusted { return cast(inout(TaskFiber))m_fiber; }
		@property size_t taskCounter() const @safe { return m_taskCounter; }
		@property inout(Thread) thread() inout @safe { if (m_fiber) return this.fiber.thread; return null; }

		/** Determines if the task is still running.
		*/
		@property bool running()
		const @trusted {
			assert(m_fiber !is null, "Invalid task handle");
			try if (this.fiber.state == Fiber.State.TERM) return false; catch (Throwable) {}
			return this.fiber.m_running && this.fiber.m_taskCounter == m_taskCounter;
		}

		// FIXME: this is not thread safe!
		@property ref ThreadInfo tidInfo() { return m_fiber ? fiber.tidInfo : s_tidInfo; }
		@property Tid tid() { return tidInfo.ident; }
	}

	T opCast(T)() const nothrow if (is(T == bool)) { return m_fiber !is null; }

	void join() { if (running) fiber.join(); }
	void interrupt() { if (running) fiber.interrupt(); }
	void terminate() { if (running) fiber.terminate(); }

	string toString() const { import std.string; return format("%s:%s", cast(void*)m_fiber, m_taskCounter); }

	bool opEquals(in ref Task other) const nothrow @safe { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
	bool opEquals(in Task other) const nothrow @safe { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
}



/** The base class for a task aka Fiber.

	This class represents a single task that is executed concurrently
	with other tasks. Each task is owned by a single thread.
*/
class TaskFiber : Fiber {
	private {
		Thread m_thread;
		import std.concurrency : ThreadInfo;
		ThreadInfo m_tidInfo;
	}

	protected {
		shared size_t m_taskCounter;
		shared bool m_running;
	}

	protected this(void delegate() fun, size_t stack_size)
	nothrow {
		super(fun, stack_size);
		m_thread = Thread.getThis();
	}

	/** Returns the thread that owns this task.
	*/
	@property inout(Thread) thread() inout @safe nothrow { return m_thread; }

	/** Returns the handle of the current Task running on this fiber.
	*/
	@property Task task() @safe nothrow { return Task(this, m_taskCounter); }

	@property ref inout(ThreadInfo) tidInfo() inout nothrow { return m_tidInfo; }

	/** Blocks until the task has ended.
	*/
	abstract void join();

	/** Throws an InterruptExeption within the task as soon as it calls a blocking function.
	*/
	abstract void interrupt();

	/** Terminates the task without notice as soon as it calls a blocking function.
	*/
	abstract void terminate();

	void bumpTaskCounter()
	@safe nothrow {
		import core.atomic : atomicOp;
		() @trusted { atomicOp!"+="(this.m_taskCounter, 1); } ();
	}
}


/** Exception that is thrown by Task.interrupt.
*/
class InterruptException : Exception {
	this()
	{
		super("Task interrupted.");
	}
}

module vibe.internal.async;

import std.traits : ParameterTypeTuple;
import std.typecons : tuple;
import vibe.core.core : hibernate, switchToTask;
import vibe.core.task : InterruptException, Task;
import vibe.core.log;
import core.time : Duration, seconds;


auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)()
if (!is(Object == Duration)) {
	Waitable!(action, cancel, ParameterTypeTuple!Callback) waitable;
	asyncAwaitAny!(true, func)(waitable);
	return tuple(waitable.results);
}

auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
{
	Waitable!(action, cancel, ParameterTypeTuple!Callback) waitable;
	asyncAwaitAny!(true, func)(timeout, waitable);
	return tuple(waitable.results);
}

auto asyncAwaitUninterruptible(Callback, alias action, string func = __FUNCTION__)()
nothrow {
	Waitable!(action, (cb) { assert(false, "Action cannot be cancelled."); }, ParameterTypeTuple!Callback) waitable;
	asyncAwaitAny!(false, func)(waitable);
	return tuple(waitable.results);
}

auto asyncAwaitUninterruptible(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
nothrow {
	Waitable!(action, cancel, ParameterTypeTuple!Callback) waitable;
	asyncAwaitAny!(false, func)(timeout, waitable);
	return tuple(waitable.results);
}

struct Waitable(alias wait, alias cancel, Results...) {
	alias Callback = void delegate(Results) @safe nothrow;
	Results results;
	bool cancelled;
	void waitCallback(Callback cb) { wait(cb); }
	void cancelCallback(Callback cb) { cancel(cb); }
}

void asyncAwaitAny(bool interruptible, string func = __FUNCTION__, Waitables...)(Duration timeout, ref Waitables waitables)
{
	if (timeout == Duration.max) asyncAwaitAny!(interruptible, func)(waitables);
	else {
		import eventcore.core;

		auto tm = eventDriver.createTimer();
		eventDriver.setTimer(tm, timeout);
		scope (exit) eventDriver.releaseRef(tm);
		Waitable!(
			cb => eventDriver.waitTimer(tm, cb),
			cb => eventDriver.cancelTimerWait(tm, cb),
			TimerID
		) timerwaitable;
		asyncAwaitAny!(interruptible, func)(timerwaitable, waitables);
	}
}

void asyncAwaitAny(bool interruptible, string func = __FUNCTION__, Waitables...)(ref Waitables waitables)
	if (Waitables.length >= 1 && !is(Waitables[0] == Duration))
{
	import std.meta : staticMap;
	import std.algorithm.searching : any;

	/*scope*/ staticMap!(CBDel, Waitables) callbacks; // FIXME: avoid heap delegates

	bool[Waitables.length] fired;
	ScopeGuard[Waitables.length] scope_guards;
	bool any_fired = false;
	Task t;

	bool still_inside = true;
	scope (exit) still_inside = false;

	logDebugV("Performing %s async operations in %s", waitables.length, func);

	foreach (i, W; Waitables) {
		/*scope*/auto cb = (typeof(Waitables[i].results) results) @safe nothrow {
			assert(still_inside, "Notification fired after asyncAwait had already returned!");
			logDebugV("Waitable %s in %s fired (istask=%s).", i, func, t != Task.init);
			fired[i] = true;
			any_fired = true;
			waitables[i].results = results;
			if (t != Task.init) switchToTask(t);
		};
		callbacks[i] = cb;

		logDebugV("Starting operation %s", i);
		waitables[i].waitCallback(callbacks[i]);

		scope ccb = {
			if (!fired[i]) {
				logDebugV("Cancelling operation %s", i);
				waitables[i].cancelCallback(callbacks[i]);
				waitables[i].cancelled = true;
				any_fired = true;
				fired[i] = true;
			}
		};
		scope_guards[i] = ScopeGuard(ccb);

		if (any_fired) {
			logDebugV("Returning to %s without waiting.", func);
			return;
		}
	}

	logDebugV("Need to wait in %s (%s)...", func, interruptible ? "interruptible" : "uninterruptible");

	t = Task.getThis();

	do {
		static if (interruptible) {
			bool interrupted = false;
			hibernate(() @safe nothrow {
				logDebugV("Got interrupted in %s.", func);
				interrupted = true;
			});
			logDebugV("Task resumed (fired=%s, interrupted=%s)", fired, interrupted);
			if (interrupted)
				throw new InterruptException;
		} else {
			hibernate();
			logDebugV("Task resumed (fired=%s)", fired);
		}
	} while (!any_fired);

	logDebugV("Return result for %s.", func);
}

private alias CBDel(Waitable) = void delegate(typeof(Waitable.results)) @safe nothrow;

private struct ScopeGuard { @safe nothrow: void delegate() op; ~this() { if (op !is null) op(); } }

@safe nothrow /*@nogc*/ unittest {
	int cnt = 0;
	auto ret = asyncAwaitUninterruptible!(void delegate(int), (cb) { cnt++; cb(42); });
	assert(ret[0] == 42);
	assert(cnt == 1);
}

@safe nothrow /*@nogc*/ unittest {
	int a, b, c;
	Waitable!(
		(cb) { a++; cb(42); },
		(cb) { assert(false); },
		int
	) w1;
	Waitable!(
		(cb) { b++; },
		(cb) { c++; },
		int
	) w2;

	asyncAwaitAny!false(w1, w2);
	assert(w1.results[0] == 42 && w2.results[0] == 0);
	assert(a == 1 && b == 0 && c == 0);

	asyncAwaitAny!false(w2, w1);
	assert(w1.results[0] == 42 && w2.results[0] == 0);
	assert(a == 2 && b == 1 && c == 1);
}

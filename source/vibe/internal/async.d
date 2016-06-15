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

	logTrace("Performing %s async operations in %s", waitables.length, func);

	foreach (i, W; Waitables) {
		callbacks[i] = (typeof(Waitables[i].results) results) @safe nothrow {
			logTrace("Waitable %s in %s fired.", i, func);
			fired[i] = true;
			any_fired = true;
			waitables[i].results = results;
			if (t != Task.init) switchToTask(t);
		};

		logTrace("Starting operation %s", i);
		waitables[i].waitCallback(callbacks[i]);
		scope_guards[i] = ScopeGuard({
			if (!fired[i]) {
				logTrace("Cancelling operation %s", i);
				waitables[i].cancelCallback(callbacks[i]);
				any_fired = true;
				fired[i] = true;
			}
		});
		if (any_fired) {
			logTrace("Returning without waiting.");
			return;
		}
	}

	logTrace("Need to wait...");
	t = Task.getThis();
	do {
		static if (interruptible) {
			bool interrupted = false;
			hibernate(() @safe nothrow {
				logTrace("Got interrupted in %s.", func);
				interrupted = true;
			});
			if (interrupted)
				throw new InterruptException;
		} else hibernate();
	} while (!any_fired);

	logTrace("Return result for %s.", func);
}

private alias CBDel(Waitable) = void delegate(typeof(Waitable.results)) @safe nothrow;

private struct ScopeGuard { @safe nothrow: void delegate() op; ~this() { if (op !is null) op(); } }

@safe nothrow /*@nogc*/ unittest {
	int cnt = 0;
	auto ret = asyncAwaitUninterruptible!(void delegate(int), (cb) { cnt++; cb(42); });
	assert(ret[0] == 42);
	assert(cnt == 1);
}
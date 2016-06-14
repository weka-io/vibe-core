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

void asyncAwaitAny(bool interruptible, string func, Waitables...)(Duration timeout, ref Waitables waitables)
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

void asyncAwaitAny(bool interruptible, string func, Waitables...)(ref Waitables waitables)
	if (Waitables.length >= 1 && !is(Waitables[0] == Duration))
{
	import std.meta : staticMap;
	import std.algorithm.searching : any;

	/*scope*/ staticMap!(CBDel, Waitables) callbacks; // FIXME: avoid heap delegates

	bool[Waitables.length] fired;
	Task t;

	foreach (i, W; Waitables) {
		callbacks[i] = (typeof(Waitables[i].results) results) @safe nothrow {
			logTrace("Waitable %s fired.", i);
			fired[i] = true;
			waitables[i].results = results;
			if (t != Task.init) switchToTask(t);
		};

		waitables[i].waitCallback(callbacks[i]);
		scope (exit) {
			if (!fired[i]) {
				waitables[i].cancelCallback(callbacks[i]);
				assert(fired[i], "The cancellation callback didn't invoke the result callback!");
			}
		}
		if (fired[i]) return;
	}

	logTrace("Need to wait...");
	t = Task.getThis();
	do {
		static if (interruptible) {
			bool interrupted = false;
			hibernate(() @safe nothrow {
				logTrace("Got interrupted.");
				interrupted = true;
			});
			if (interrupted)
				throw new InterruptException;
		} else hibernate();
	} while (!fired[].any());

	logTrace("Return result.");
}

private alias CBDel(Waitable) = void delegate(typeof(Waitable.results)) @safe nothrow;

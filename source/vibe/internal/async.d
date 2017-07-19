module vibe.internal.async;

import std.traits : ParameterTypeTuple;
import std.typecons : tuple;
import vibe.core.core : hibernate, switchToTask;
import vibe.core.task : InterruptException, Task;
import vibe.core.log;
import core.time : Duration, seconds;


auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)()
if (!is(Object == Duration)) {
	Waitable!(Callback, action, cancel) waitable;
	asyncAwaitAny!(true, func)(waitable);
	return tuple(waitable.results);
}

auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
{
	Waitable!(Callback, action, cancel) waitable;
	asyncAwaitAny!(true, func)(timeout, waitable);
	static struct R {
		bool completed;
		typeof(waitable.results) results;
	}
	return R(!waitable.cancelled, waitable.results);
}

auto asyncAwaitUninterruptible(Callback, alias action, string func = __FUNCTION__)()
nothrow {
	static if (is(typeof(action(Callback.init)) == void)) void cancel(Callback) { assert(false, "Action cannot be cancelled."); }
	else void cancel(Callback, typeof(action(Callback.init))) { assert(false, "Action cannot be cancelled."); }
	Waitable!(Callback, action, cancel) waitable;
	asyncAwaitAny!(false, func)(waitable);
	return tuple(waitable.results);
}

auto asyncAwaitUninterruptible(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
nothrow {
	Waitable!(Callback, action, cancel) waitable;
	asyncAwaitAny!(false, func)(timeout, waitable);
	return tuple(waitable.results);
}

struct Waitable(CB, alias wait, alias cancel, on_result...)
	if (on_result.length <= 1)
{
	import std.traits : ReturnType;

	alias Callback = CB;

	static if (on_result.length == 0) {
		static assert(!hasAnyScopeParameter!Callback, "Need to retrieve results with a callback because of scoped parameter");
		ParameterTypeTuple!Callback results;
		void setResult(ref ParameterTypeTuple!Callback r) { this.results = r; }
	} else {
		import std.format : format;
		alias PTypes = ParameterTypeTuple!Callback;
		mixin(q{void setResult(%s) { on_result[0](%s); }}.format(generateParamDecls!Callback, generateParamNames!Callback));
	}

	bool cancelled;
	auto waitCallback(Callback cb) nothrow { return wait(cb); }

	static if (is(ReturnType!waitCallback == void))
		void cancelCallback(Callback cb) nothrow { cancel(cb); }
	else
		void cancelCallback(Callback cb, ReturnType!waitCallback r) nothrow { cancel(cb, r); }
}

void asyncAwaitAny(bool interruptible, string func = __FUNCTION__, Waitables...)(Duration timeout, ref Waitables waitables)
{
	if (timeout == Duration.max) asyncAwaitAny!(interruptible, func)(waitables);
	else {
		import eventcore.core;

		auto tm = eventDriver.timers.create();
		eventDriver.timers.set(tm, timeout, 0.seconds);
		scope (exit) eventDriver.timers.releaseRef(tm);
		Waitable!(TimerCallback,
			cb => eventDriver.timers.wait(tm, cb),
			cb => eventDriver.timers.cancelWait(tm)
		) timerwaitable;
		asyncAwaitAny!(interruptible, func)(timerwaitable, waitables);
	}
}

void asyncAwaitAny(bool interruptible, string func = __FUNCTION__, Waitables...)(ref Waitables waitables)
	if (Waitables.length >= 1 && !is(Waitables[0] == Duration))
{
	import std.meta : staticMap;
	import std.algorithm.searching : any;
	import std.format : format;
	import std.meta : AliasSeq;
	import std.traits : ReturnType;

	/*scope*/ staticMap!(CBDel, Waitables) callbacks; // FIXME: avoid heap delegates

	bool[Waitables.length] fired;
	ScopeGuard[Waitables.length] scope_guards;
	bool any_fired = false;
	Task t;

	bool still_inside = true;
	scope (exit) still_inside = false;

	debug(VibeAsyncLog) logDebugV("Performing %s async operations in %s", waitables.length, func);

	() @trusted { logDebugV("si %x", &still_inside); } ();

	foreach (i, W; Waitables) {
		alias PTypes = ParameterTypeTuple!(CBDel!W);
		/*scope*/auto cb = mixin(q{(%s) @safe nothrow {
	() @trusted { logDebugV("siw %%x", &still_inside); } ();
			debug(VibeAsyncLog) logDebugV("Waitable %%s in %%s fired (istask=%%s).", i, func, t != Task.init);
			assert(still_inside, "Notification fired after asyncAwait had already returned!");
			fired[i] = true;
			any_fired = true;
			static if (PTypes.length)
				waitables[i].setResult(%s);
			if (t != Task.init) switchToTask(t);
		}}.format(generateParamDecls!(CBDel!W), generateParamNames!(CBDel!W)));
		callbacks[i] = cb;

		debug(VibeAsyncLog) logDebugV("Starting operation %s", i);
		static if (is(ReturnType!(W.waitCallback) == void))
			waitables[i].waitCallback(callbacks[i]);
		else
			auto wr = waitables[i].waitCallback(callbacks[i]);

		scope ccb = () @safe nothrow {
			if (!fired[i]) {
				debug(VibeAsyncLog) logDebugV("Cancelling operation %s", i);
				static if (is(ReturnType!(W.waitCallback) == void))
					waitables[i].cancelCallback(callbacks[i]);
				else
					waitables[i].cancelCallback(callbacks[i], wr);
				waitables[i].cancelled = true;
				any_fired = true;
				fired[i] = true;
			}
		};
		scope_guards[i] = ScopeGuard(ccb);

		if (any_fired) {
			debug(VibeAsyncLog) logDebugV("Returning to %s without waiting.", func);
			return;
		}
	}

	debug(VibeAsyncLog) logDebugV("Need to wait in %s (%s)...", func, interruptible ? "interruptible" : "uninterruptible");

	t = Task.getThis();

	debug (VibeAsyncLog) scope (failure) logDebugV("Aborting wait due to exception");

	do {
		static if (interruptible) {
			bool interrupted = false;
			hibernate(() @safe nothrow {
				debug(VibeAsyncLog) logDebugV("Got interrupted in %s.", func);
				interrupted = true;
			});
			debug(VibeAsyncLog) logDebugV("Task resumed (fired=%s, interrupted=%s)", fired, interrupted);
			if (interrupted)
				throw new InterruptException;
		} else {
			hibernate();
			debug(VibeAsyncLog) logDebugV("Task resumed (fired=%s)", fired);
		}
	} while (!any_fired);

	debug(VibeAsyncLog) logDebugV("Return result for %s.", func);
}

private alias CBDel(Waitable) = Waitable.Callback;

private struct ScopeGuard { @safe nothrow: void delegate() op; ~this() { if (op !is null) op(); } }

@safe nothrow /*@nogc*/ unittest {
	int cnt = 0;
	auto ret = asyncAwaitUninterruptible!(void delegate(int) @safe nothrow, (cb) { cnt++; cb(42); });
	assert(ret[0] == 42);
	assert(cnt == 1);
}

@safe nothrow /*@nogc*/ unittest {
	int a, b, c;
	Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { a++; cb(42); },
		(cb) { assert(false); }
	) w1;
	Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { b++; },
		(cb) { c++; }
	) w2;
	Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { c++; cb(42); },
		(cb) { assert(false); },
		(int n) { assert(n == 42); }
	) w3;

	asyncAwaitAny!false(w1, w2);
	assert(w1.results[0] == 42 && w2.results[0] == 0);
	assert(a == 1 && b == 0 && c == 0);

	asyncAwaitAny!false(w2, w1);
	assert(w1.results[0] == 42 && w2.results[0] == 0);
	assert(a == 2 && b == 1 && c == 1);

	asyncAwaitAny!false(w3);
	assert(c == 2);
}

private string generateParamDecls(Fun)()
{
	import std.format : format;
	import std.traits : ParameterTypeTuple, ParameterStorageClass, ParameterStorageClassTuple;

	alias Types = ParameterTypeTuple!Fun;
	alias SClasses = ParameterStorageClassTuple!Fun;
	string ret;
	foreach (i, T; Types) {
		static if (i > 0) ret ~= ", ";
		static if (SClasses[i] & ParameterStorageClass.lazy_) ret ~= "lazy ";
		static if (SClasses[i] & ParameterStorageClass.scope_) ret ~= "scope ";
		static if (SClasses[i] & ParameterStorageClass.out_) ret ~= "out ";
		static if (SClasses[i] & ParameterStorageClass.ref_) ret ~= "ref ";
		ret ~= format("PTypes[%s] param_%s", i, i);
	}
	return ret;
}

private string generateParamNames(Fun)()
{
	import std.format : format;

	string ret;
	foreach (i, T; ParameterTypeTuple!Fun) {
		static if (i > 0) ret ~= ", ";
		ret ~= format("param_%s", i);
	}
	return ret;
}

private template hasAnyScopeParameter(Callback) {
	import std.algorithm.searching : any;
	import std.traits : ParameterStorageClass, ParameterStorageClassTuple;
	alias SC = ParameterStorageClassTuple!Callback;
	static if (SC.length == 0) enum hasAnyScopeParameter = false;
	else enum hasAnyScopeParameter = any!(c => c & ParameterStorageClass.scope_)([SC]);
}

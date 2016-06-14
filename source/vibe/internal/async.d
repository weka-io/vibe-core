module vibe.internal.async;

import std.traits : ParameterTypeTuple;
import std.typecons : tuple;
import vibe.core.core : hibernate, switchToTask;
import vibe.core.task : InterruptException, Task;
import vibe.core.log;
import core.time : Duration, seconds;


auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)()
if (!is(Object == Duration)) {
	return asyncAwaitImpl!(true, Callback, action, cancel, func)(Duration.max);
}

auto asyncAwait(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
{
	return asyncAwaitImpl!(true, Callback, action, cancel, func)(timeout);
}

auto asyncAwaitUninterruptible(Callback, alias action, string func = __FUNCTION__)()
nothrow {
	return asyncAwaitImpl!(false, Callback, action, (cb) { assert(false); }, func)(Duration.max);
}

auto asyncAwaitUninterruptible(Callback, alias action, alias cancel, string func = __FUNCTION__)(Duration timeout)
nothrow {
	assert(timeout >= 0.seconds);
	asyncAwaitImpl!(false, Callback, action, cancel, func)(timeout);
}

private auto asyncAwaitImpl(bool interruptible, Callback, alias action, alias cancel, string func)(Duration timeout)
@safe if (!is(Object == Duration)) {
	alias CBTypes = ParameterTypeTuple!Callback;

	assert(timeout >= 0.seconds);
	assert(timeout == Duration.max, "TODO!");

	bool fired = false;
	CBTypes ret;
	Task t;

	void callback(CBTypes params)
	@safe nothrow {
		logTrace("Got result.");
		fired = true;
		ret = params;
		if (t != Task.init) switchToTask(t);
	}

	scope cbdel = &callback;

	logTrace("Calling async function in "~func);
	action(cbdel);
	if (!fired) {
		logTrace("Need to wait...");
		t = Task.getThis();
		do {
			static if (interruptible) {
				bool interrupted = false;
				hibernate(() @safe nothrow {
					cancel(cbdel);
					interrupted = true;
				});
				if (interrupted)
					throw new InterruptException; // FIXME: the original operation needs to be stopped! or the callback will still be called"
			} else hibernate();
		} while (!fired);
	}
	logTrace("Return result.");
	return tuple(ret);
}

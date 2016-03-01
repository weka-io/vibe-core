module vibe.internal.async;

import std.traits : ParameterTypeTuple;
import std.typecons : tuple;
import vibe.core.core;
import vibe.core.log;
import core.time : Duration, seconds;


auto asyncAwait(string method, Object, ARGS...)(Object object, ARGS args)
{
	alias CB = ParameterTypeTuple!(__traits(getMember, Object, method))[$-1];
	alias CBTypes = ParameterTypeTuple!CB;

	bool fired = false;
	CBTypes ret;
	Task t;

	void callback(CBTypes params)
	@safe nothrow {
		logTrace("Got result.");
		fired = true;
		ret = params;
		if (t != Task.init)
			resumeTask(t);
	}

	logTrace("Calling %s...", method);
	__traits(getMember, object, method)(args, &callback);
	if (!fired) {
		logTrace("Need to wait...");
		t = Task.getThis();
		do yieldForEvent();
		while (!fired);
	}
	logTrace("Return result.");
	return tuple(ret);
}

auto asyncAwait(string method, Object, ARGS...)(Duration timeout, Object object, ARGS args)
{
	assert(timeout >= 0.seconds);
	if (timeout == Duration.max) return asyncAwait(object, args);
	else assert(false, "TODO!");
}

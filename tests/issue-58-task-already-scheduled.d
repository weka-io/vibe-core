/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.sync;
import vibe.core.core;
import std.datetime;
import core.atomic;

shared ManualEvent ev;
shared size_t counter;

shared static this()
{
	ev = createSharedManualEvent();
}

void main()
{
	setTaskStackSize(64*1024);

	runTask({
		foreach (x; 0 .. 500) {
			runWorkerTask(&worker);
		}
	});

	setTimer(dur!"msecs"(10), { ev.emit(); });
	setTimer(dur!"seconds"(20), { assert(false, "Timers didn't fire within the time limit"); });

	runApplication();

	assert(atomicLoad(counter) == 500, "Event loop exited prematurely.");
}

void worker()
{
	ev.wait();
	ev.emit();
	setTimer(dur!"seconds"(1), {
		auto c = atomicOp!"+="(counter, 1);
		if (c == 500) exitEventLoop(true);
	});
}

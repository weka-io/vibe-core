/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
	debugVersions "VibeTaskLog" "VibeAsyncLog"
+/
module tests;

import vibe.core.core;
import vibe.core.log;
import vibe.core.sync;
import core.time;
import core.stdc.stdlib : exit;


void main()
{
	setTimer(5.seconds, { logError("Test has hung."); exit(1); });

	Task t;

	runTask({
		t = runTask({ sleep(100.msecs); });
		t.join();
	});

	// let the outer task run and start the inner task
	yield();
	// let the outer task get another execution slice to write to t
	yield();

	assert(t && t.running);

	t.join();
}

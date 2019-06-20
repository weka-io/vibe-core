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

	yield();

	assert(t && t.running);

	t.join();
}

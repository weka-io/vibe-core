/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.channel;
import vibe.core.core;
import core.time;

void main()
{
	auto ch = createChannel!int();

	auto p = runTask({
		sleep(1.seconds);
		ch.close();
	});

	auto c = runTask({
		while (!ch.empty) {
			try ch.consumeOne();
			catch (Exception e) assert(false, e.msg);
		}
	});

	p.join();
	c.join();
}

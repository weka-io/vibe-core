/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;

void main()
{
	foreach (_; 0 .. 20) {
		TCPConnection conn;
		try {
			conn = connectTCP("127.0.0.1", 16565);
			logError("Connection: %s", conn);
			conn.close();
			assert(false, "Didn't expect TCP connection on port 16565 to succeed");
		} catch (Exception) { }
	}
}
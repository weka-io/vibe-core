import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
//import vibe.stream.operations;

import std.exception : enforce;
import std.functional : toDelegate;


void main()
{
	void staticAnswer(TCPConnection conn)
	nothrow @safe {
		try {
			while (!conn.empty) {
				logInfo("read request");
				while (true) {
					CountingRange r;
					conn.readLine(r);
					if (!r.count) break;
				}
				logInfo("write answer");
				conn.write(cast(const(ubyte)[])"HTTP/1.1 200 OK\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello, World!");
				logInfo("flush");
				conn.flush();
				logInfo("wait for next request");
			}
			logInfo("out");
		} catch (Exception e) {
			scope (failure) assert(false);
			logError("Error processing request: %s", e.msg);
		}
	}

	auto listener = listenTCP(8080, &staticAnswer, "127.0.0.1");

	runEventLoop();
}

struct CountingRange {
	@safe nothrow @nogc:
	ulong count = 0;
	void put(ubyte) { count++; }
	void put(in ubyte[] arr) { count += arr.length; }
}


import std.range.primitives : isOutputRange;

void readLine(R, InputStream)(InputStream stream, ref R dst, size_t max_bytes = size_t.max)
	if (isOutputRange!(R, ubyte))
{
	import std.algorithm.comparison : min, max;
	import std.algorithm.searching : countUntil;

	enum end_marker = "\r\n";

	assert(end_marker.length >= 1 && end_marker.length <= 2);

	size_t nmatched = 0;
	size_t nmarker = end_marker.length;

	while (true) {
		enforce(!stream.empty, "Reached EOF while searching for end marker.");
		enforce(max_bytes > 0, "Reached maximum number of bytes while searching for end marker.");
		auto max_peek = max(max_bytes, max_bytes+nmarker); // account for integer overflow
		auto pm = stream.peek()[0 .. min($, max_bytes)];
		if (!pm.length) { // no peek support - inefficient route
			ubyte[2] buf = void;
			auto l = nmarker - nmatched;
			stream.read(buf[0 .. l]);
			foreach (i; 0 .. l) {
				if (buf[i] == end_marker[nmatched]) {
					nmatched++;
				} else if (buf[i] == end_marker[0]) {
					foreach (j; 0 .. nmatched) dst.put(end_marker[j]);
					nmatched = 1;
				} else {
					foreach (j; 0 .. nmatched) dst.put(end_marker[j]);
					nmatched = 0;
					dst.put(buf[i]);
				}
				if (nmatched == nmarker) return;
			}
		} else {
			auto idx = pm.countUntil(end_marker[0]);
			if (idx < 0) {
				dst.put(pm);
				max_bytes -= pm.length;
				stream.skip(pm.length);
			} else {
				dst.put(pm[0 .. idx]);
				stream.skip(idx+1);
				if (nmarker == 2) {
					ubyte[1] next;
					stream.read(next);
					if (next[0] == end_marker[1])
						return;
					dst.put(end_marker[0]);
					dst.put(next[0]);
				} else return;
			}
		}
	}
}

static if (!is(typeof(TCPConnection.init.skip(0))))
{
	private void skip(ref TCPConnection str, ulong count)
	{
		ubyte[156] buf = void;
		while (count > 0) {
			auto n = min(buf.length, count);
			str.read(buf[0 .. n]);
			count -= n;
		}
	}
}

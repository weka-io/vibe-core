import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
//import vibe.stream.operations;

import std.functional : toDelegate;

void main()
{
	void staticAnswer(TCPConnection conn)
	nothrow @safe {
		try {
			while (!conn.empty) {
				while (true) {
					CountingRange r;
					conn.readLine(r);
					if (!r.count) break;
				}
				conn.write(cast(const(ubyte)[])"HTTP/1.1 200 OK\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello, World!");
				conn.flush();
			}
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

/**
	Reads and returns a single line from the stream.

	Throws:
		An exception if either the stream end was hit without hitting a newline first, or
		if more than max_bytes have been read from the stream.
*/
ubyte[] readLine(InputStream)(InputStream stream, size_t max_bytes = size_t.max, string linesep = "\r\n", Allocator alloc = defaultAllocator()) /*@ufcs*/
{
	auto output = AllocAppender!(ubyte[])(alloc);
	output.reserve(max_bytes < 64 ? max_bytes : 64);
	readLine(stream, output, max_bytes, linesep);
	return output.data();
}
/// ditto
void readLine(InputStream, OutputStream)(InputStream stream, OutputStream dst, size_t max_bytes = size_t.max, string linesep = "\r\n")
{
	import vibe.stream.wrapper;
	auto dstrng = StreamOutputRange(dst);
	readLine(stream, dstrng, max_bytes, linesep);
}
/// ditto
void readLine(R, InputStream)(InputStream stream, ref R dst, size_t max_bytes = size_t.max, string linesep = "\r\n")
	if (isOutputRange!(R, ubyte))
{
	readUntil(stream, dst, cast(const(ubyte)[])linesep, max_bytes);
}


/**
	Reads all data of a stream until the specified end marker is detected.

	Params:
		stream = The input stream which is searched for end_marker
		end_marker = The byte sequence which is searched in the stream
		max_bytes = An optional limit of how much data is to be read from the
			input stream; if the limit is reaached before hitting the end
			marker, an exception is thrown.
		alloc = An optional allocator that is used to build the result string
			in the string variant of this function
		dst = The output stream, to which the prefix to the end marker of the
			input stream is written

	Returns:
		The string variant of this function returns the complete prefix to the
		end marker of the input stream, excluding the end marker itself.

	Throws:
		An exception if either the stream end was hit without hitting a marker
		first, or if more than max_bytes have been read from the stream in
		case of max_bytes != 0.

	Remarks:
		This function uses an algorithm inspired by the
		$(LINK2 http://en.wikipedia.org/wiki/Boyer%E2%80%93Moore_string_search_algorithm,
		Boyer-Moore string search algorithm). However, contrary to the original
		algorithm, it will scan the whole input string exactly once, without
		jumping over portions of it. This allows the algorithm to work with
		constant memory requirements and without the memory copies that would
		be necessary for streams that do not hold their complete data in
		memory.

		The current implementation has a run time complexity of O(n*m+m²) and
		O(n+m) in typical cases, with n being the length of the scanned input
		string and m the length of the marker.
*/
ubyte[] readUntil(InputStream)(InputStream stream, in ubyte[] end_marker, size_t max_bytes = size_t.max, Allocator alloc = defaultAllocator()) /*@ufcs*/
{
	auto output = AllocAppender!(ubyte[])(alloc);
	output.reserve(max_bytes < 64 ? max_bytes : 64);
	readUntil(stream, output, end_marker, max_bytes);
	return output.data();
}
/// ditto
void readUntil(InputStream, OutputStream)(InputStream stream, OutputStream dst, in ubyte[] end_marker, ulong max_bytes = ulong.max) /*@ufcs*/
{
	import vibe.stream.wrapper;
	auto dstrng = StreamOutputRange(dst);
	readUntil(stream, dstrng, end_marker, max_bytes);
}
/// ditto
void readUntil(R, InputStream)(InputStream stream, ref R dst, in ubyte[] end_marker, ulong max_bytes = ulong.max) /*@ufcs*/
	if (isOutputRange!(R, ubyte))
{
	assert(max_bytes > 0 && end_marker.length > 0);

	if (end_marker.length <= 2)
		readUntilSmall(stream, dst, end_marker, max_bytes);
	else
		readUntilGeneric(stream, dst, end_marker, max_bytes);
}

private void readUntilSmall(R, InputStream)(InputStream stream, ref R dst, in ubyte[] end_marker, ulong max_bytes = ulong.max)
@safe {
	import std.algorithm.comparison : min, max;
	import std.algorithm.searching : countUntil;

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

private final class Buffer { ubyte[64*1024-4*size_t.sizeof] bytes = void; } // 64k - some headroom for 

private void readUntilGeneric(R, InputStream)(InputStream stream, ref R dst, in ubyte[] end_marker, ulong max_bytes = ulong.max) /*@ufcs*/
	if (isOutputRange!(R, ubyte))
{
	import std.algorithm.comparison : min;
	// allocate internal jump table to optimize the number of comparisons
	size_t[8] nmatchoffsetbuffer = void;
	size_t[] nmatchoffset;
	if (end_marker.length <= nmatchoffsetbuffer.length) nmatchoffset = nmatchoffsetbuffer[0 .. end_marker.length];
	else nmatchoffset = new size_t[end_marker.length];

	// precompute the jump table
	nmatchoffset[0] = 0;
	foreach( i; 1 .. end_marker.length ){
		nmatchoffset[i] = i;
		foreach_reverse( j; 1 .. i )
			if( end_marker[j .. i] == end_marker[0 .. i-j] ){
				nmatchoffset[i] = i-j;
				break;
			}
		assert(nmatchoffset[i] > 0 && nmatchoffset[i] <= i);
	}

	size_t nmatched = 0;
	scope bufferobj = new Buffer; // FIXME: use heap allocation
	auto buf = bufferobj.bytes[];

	ulong bytes_read = 0;

	void skip2(size_t nbytes)
	{
		bytes_read += nbytes;
		stream.skip(nbytes);
	}

	while( !stream.empty ){
		enforce(bytes_read < max_bytes, "Reached byte limit before reaching end marker.");

		// try to get as much data as possible, either by peeking into the stream or
		// by reading as much as isguaranteed to not exceed the end marker length
		// the block size is also always limited by the max_bytes parameter.
		size_t nread = 0;
		auto least_size = stream.leastSize(); // NOTE: blocks until data is available
		auto max_read = max_bytes - bytes_read;
		auto str = stream.peek(); // try to get some data for free
		if( str.length == 0 ){ // if not, read as much as possible without reading past the end
			nread = min(least_size, end_marker.length-nmatched, buf.length, max_read);
			stream.read(buf[0 .. nread]);
			str = buf[0 .. nread];
			bytes_read += nread;
		} else if( str.length > max_read ){
			str.length = cast(size_t)max_read;
		}

		// remember how much of the marker was already matched before processing the current block
		size_t nmatched_start = nmatched;

		// go through the current block trying to match the marker
		size_t i = 0;
		for (i = 0; i < str.length; i++) {
			auto ch = str[i];
			// if we have a mismatch, use the jump table to try other possible prefixes
			// of the marker
			while( nmatched > 0 && ch != end_marker[nmatched] )
				nmatched -= nmatchoffset[nmatched];

			// if we then have a match, increase the match count and test for full match
			if (ch == end_marker[nmatched])
				if (++nmatched == end_marker.length) {
					i++;
					break;
				}
		}


		// write out any false match part of previous blocks
		if( nmatched_start > 0 ){
			if( nmatched <= i ) dst.put(end_marker[0 .. nmatched_start]);
			else dst.put(end_marker[0 .. nmatched_start-nmatched+i]);
		}

		// write out any unmatched part of the current block
		if( nmatched < i ) dst.put(str[0 .. i-nmatched]);

		// got a full, match => out
		if (nmatched >= end_marker.length) {
			// in case of a full match skip data in the stream until the end of
			// the marker
			skip2(i - nread);
			return;
		}

		// otherwise skip this block in the stream
		skip2(str.length - nread);
	}

	enforce(false, "Reached EOF before reaching end marker.");
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

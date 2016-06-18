module vibe.core.stream;

enum isInputStream(T) = __traits(compiles, {
	T s;
	ubyte[] buf;
	if (!s.empty)
		s.read(buf);
	if (s.leastSize > 0)
		s.read(buf);
});

enum isOutputStream(T) = __traits(compiles, {
	T s;
	const(ubyte)[] buf;
	s.write(buf);
});

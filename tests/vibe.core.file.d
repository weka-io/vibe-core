/++ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.file;

void main()
{
	auto f = openFile("test.dat", FileMode.createTrunc);
	assert(f.size == 0);
	f.write([1, 2, 3, 4, 5]);
	assert(f.size == 5);
	f.seek(0);
	f.write([1, 2, 3, 4, 5]);
	assert(f.size == 5);
	f.write([6, 7, 8, 9, 10]);
	assert(f.size == 10);
	ubyte[5] dst;
	f.seek(2);
	f.read(dst);
	assert(dst[] == [3, 4, 5, 6, 7]);
}

module vibe.core.path;

import std.exception : enforce;

static import std.path;


struct Path {
	@safe:
	private string m_path;

	this(string p)
	nothrow {
		m_path = p;
	}

	@property bool absolute()
	{
		import std.algorithm.searching : startsWith;
		// FIXME: Windows paths!
		return m_path.startsWith('/');
	}

	@property void endsWithSlash(bool v)
	{
		import std.algorithm.searching : endsWith;

		if (!m_path.endsWith('/') && v) m_path ~= '/';
		else if (m_path.endsWith('/') && !v) m_path = m_path[0 .. $-1]; // FIXME: "/test//" -> "/test/"
	}

	@property bool empty() const { return m_path.length == 0 || m_path == "/"; }


	Path parentPath()
	{
		import std.string : lastIndexOf;
		auto idx = m_path.lastIndexOf('/');
		version (Windows) {
			auto idx2 = m_path.lastIndexOf('\\');
			if (idx2 > idx) idx = idx2;
		}
		enforce(idx > 0, "Path has no parent path.");
		return Path(m_path[0 .. idx+1]);
	}

	Path relativeTo(Path p) { assert(false, "TODO!"); }
	Path relativeToWeb(Path p) { assert(false, "TODO!"); }

	void normalize()
	{
		assert(false, "TODO!");
	}

	// FIXME: this should decompose the two paths into their parts and compare the part sequence
	bool startsWith(Path other) const {
		import std.algorithm.searching : startsWith;
		return m_path[].startsWith(other.m_path);
	}

	string toString() const nothrow { return m_path; }

	string toNativeString() const nothrow { return m_path; }

	PathEntry opIndex(size_t idx)
	const {
		import std.string : indexOf;

		string s = m_path;
		while (true) {
			auto sidx = m_path.indexOf('/');
			if (idx == 0) break;
			enforce(sidx > 0, "Index out of bounds");
			s = s[sidx+1 .. $];
			idx--;
		}

		auto sidx = s.indexOf('/');
		return PathEntry(s[0 .. sidx >= 0 ? sidx : $]);
	}

	Path opBinary(string op : "~")(string subpath) { return this ~ Path(subpath); }
	Path opBinary(string op : "~")(Path subpath) { return Path(std.path.buildPath(m_path, subpath.toString())); }
}

struct PathEntry {
	nothrow: @safe:
	private string m_name;

	this(string name)
	{
		m_name = name;
	}

	alias toString this;

	string toString() { return m_name; }
}

private enum PathType {
	unix,
	windows,
	inet
}

private struct PathEntryRange(PathType TYPE) {
	enum type = TYPE;
	private {
		string m_path;
		PathEntry m_front;
	}

	this(string path)
	{
		m_path = path;
		skipLeadingSeparator();
	}

	@property bool empty() const { return m_path.length == 0; }

	@property ref const(PathEntry) front() const { return m_front; }

	void popFront()
	{
		import std.string : indexOf;

		auto idx = m_path.indexOf('/');
		static if (type == PathType.windows) {
			if (idx >= 0) {
				auto idx2 = m_path[0 .. idx].indexOf('\\');
				if (idx2 >= 0) idx = idx2;
			} else idx = m_path.indexOf('\\');
		}
		
		if (idx < 0) {
			m_front = PathEntry(m_path);
			m_path = null;
		} else {
			m_front = PathEntry(m_path[0 .. idx]);
			m_path = m_path[idx+1 .. $];
		}
	}

	private void skipLeadingSeparator()
	{
		import std.algorithm.searching : startsWith;

		if (m_path.startsWith('/')) m_path = m_path[1 .. $];
		else static if (type == PathType.windows) {
			if (m_path.startsWith('\\')) m_path = m_path[1 .. $];
		}
	}
}

/*unittest {
	import std.algorithm.comparison : equal;

	assert(PathEntryRange!(PathType.unix)("hello/world").equal([PathEntry("hello"), PathEntry("world")]));
	assert(PathEntryRange!(PathType.unix)("/hello/world/").equal([PathEntry("hello"), PathEntry("world")]));
	assert(PathEntryRange!(PathType.unix)("hello\\world").equal([PathEntry("hello\\world")]));
	assert(PathEntryRange!(PathType.windows)("hello/world").equal([PathEntry("hello"), PathEntry("world")]));
	assert(PathEntryRange!(PathType.windows)("/hello/world/").equal([PathEntry("hello"), PathEntry("world")]));
	assert(PathEntryRange!(PathType.windows)("hello\\w/orld").equal([PathEntry("hello"), PathEntry("w"), PathEntry("orld")]));
	assert(PathEntryRange!(PathType.windows)("hello/w\\orld").equal([PathEntry("hello"), PathEntry("w"), PathEntry("orld")]));
}*/

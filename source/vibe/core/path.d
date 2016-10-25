module vibe.core.path;

static import std.path;

struct Path {
	nothrow: @safe:
	private string m_path;

	this(string p)
	{
		m_path = p;
	}

	string toString() const { return m_path; }

	string toNativeString() const { return m_path; }

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
}

module vibe.core.path;

struct Path {
	nothrow: @safe:
	private string m_path;

	this(string p)
	{
		m_path = p;
	}

	string toString() const { return m_path; }

	string toNativeString() const { return m_path; }
}

struct PathEntry {
	nothrow: @safe:
	private string m_name;

	this(string name)
	{
		m_name = name;
	}
}

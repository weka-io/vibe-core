module vibe.core.path;

import std.algorithm.searching : commonPrefix, endsWith, startsWith;
import std.algorithm.comparison : min;
import std.algorithm.iteration : map;
import std.exception : enforce;
import std.range : popFrontExactly, takeExactly;
import std.range.primitives : ElementType, isInputRange;


/** Computes the relative path from `base_path` to this path.

	Params:
		path = The destination path
		base_path = The path from which the relative path starts

	See_also: `relativeToWeb`
*/
Path relativeTo(Path path, Path base_path)
@safe {
	import std.array : replicate;
	import std.array : array;

	assert(path.absolute && base_path.absolute, "Both arguments to relativeTo must be absolute paths.");
	if (path.type == PathType.windows) {
		// a path such as ..\C:\windows is not valid, so force the path to stay absolute in this case
		if (path.absolute && !path.empty &&
			(path.front.toString().endsWith(":") && !base_path.startsWith(path[0 .. 1]) ||
			path.front == "\\" && !base_path.startsWith(path[0 .. min(2, $)])))
		{
			return path;
		}
	}

	size_t base = commonPrefix(path[], base_path[]).length;

	auto ret = Path("../".replicate(base_path.length - base), path.type) ~ path[base .. $];
	if (path.endsWithSlash && !ret.endsWithSlash) ret ~= Path("./");
	return ret;
}

///
unittest {
	with (PathType) {
		import std.array : array;
		import std.conv : to;
		assert(Path("/some/path", posix).relativeTo(Path("/", posix)) == Path("some/path", posix));
		assert(Path("/some/path/", posix).relativeTo(Path("/some/other/path/", posix)) == Path("../../path/", posix));
		assert(Path("/some/path/", posix).relativeTo(Path("/some/other/path", posix)) == Path("../../path/", posix));

		assert(Path("C:\\some\\path", windows).relativeTo(Path("C:\\", windows)) == Path("some\\path", windows));
		assert(Path("C:\\some\\path\\", windows).relativeTo(Path("C:\\some\\other\\path/", windows)) == Path("..\\..\\path\\", windows));
		assert(Path("C:\\some\\path\\", windows).relativeTo(Path("C:\\some\\other\\path", windows)) == Path("..\\..\\path\\", windows));

		assert(Path("\\\\server\\some\\path", windows).relativeTo(Path("\\\\server\\", windows)) == Path("some\\path", windows));
		assert(Path("\\\\server\\some\\path\\", windows).relativeTo(Path("\\\\server\\some\\other\\path/", windows)) == Path("..\\..\\path\\", windows));
		assert(Path("\\\\server\\some\\path\\", windows).relativeTo(Path("\\\\server\\some\\other\\path", windows)) == Path("..\\..\\path\\", windows));

		assert(Path("C:\\some\\path", windows).relativeTo(Path("D:\\", windows)) == Path("C:\\some\\path", windows));
		assert(Path("C:\\some\\path\\", windows).relativeTo(Path("\\\\server\\share", windows)) == Path("C:\\some\\path\\", windows));
		assert(Path("\\\\server\\some\\path\\", windows).relativeTo(Path("C:\\some\\other\\path", windows)) == Path("\\\\server\\some\\path\\", windows));
	}
}


/** Computes the relative path to this path from `base_path` using web path rules.

	The difference to `relativeTo` is that a path not ending in a slash
	will not be considered as a path to a directory and the parent path
	will instead be used.

	Params:
		path = The destination path
		base_path = The path from which the relative path starts

	See_also: `relativeTo`
*/
Path relativeToWeb(Path path, Path base_path)
@safe {
	if (!base_path.endsWithSlash) {
		if (base_path.length > 0) base_path = base_path.parentPath;
		else base_path = Path("/", path.type);
	}
	return path.relativeTo(base_path);
}

///
unittest {
	with (PathType) {
		assert(Path("/some/path", inet).relativeToWeb(Path("/", inet)) == Path("some/path", inet));
		assert(Path("/some/path/", inet).relativeToWeb(Path("/some/other/path/", inet)) == Path("../../path/", inet));
		assert(Path("/some/path/", inet).relativeToWeb(Path("/some/other/path", inet)) == Path("../path/", inet));
	}
}

struct Path {
@safe:
	private {
		string m_path;
		size_t m_length;
		size_t m_nextEntry = size_t.max;
		PathType m_type;
		bool m_absolute;
	}

	this(string p, PathType type = PathType.native)
		nothrow @nogc
	{
		import std.range.primitives : walkLength;

		m_path = p;
		m_type = type;
		setupPath();
	}

	@property bool absolute() const nothrow @nogc { return m_absolute; }

	@property bool empty() const nothrow @nogc { return m_path.length == 0; }

	@property size_t length() const nothrow @nogc { return m_length; }

	@property PathType type() const nothrow @nogc { return m_type; }

	@property PathEntry front() const nothrow @nogc { return PathEntry(m_path[0 .. m_nextEntry], m_type, m_absolute); }

	@property Path save() const nothrow @nogc { return this; }

	@property bool endsWithSlash()
	const nothrow @nogc {
		import std.algorithm.comparison : among;

		final switch (m_type) {
			case PathType.posix, PathType.inet:
				return m_path.length > 0 && m_path[$-1] == '/';
			case PathType.windows:
				return m_path.length > 0 && m_path[$-1].among('/', '\\');
		}
	}

	@property void endsWithSlash(bool v)
	nothrow {
		bool ews = this.endsWithSlash;

		final switch (m_type) {
			case PathType.posix, PathType.inet:
				if (!ews && v) m_path ~= '/';
				else if (ews && !v) m_path = m_path[0 .. $-1]; // FIXME: "/test//" -> "/test/"
				break;
			case PathType.windows:
				if (!ews && v) m_path ~= '\\';
				else if (ews && !v) m_path = m_path[0 .. $-1]; // FIXME: "/test//" -> "/test/"
				break;
		}
	}

	void popFront()
	nothrow @nogc {
		import std.string : indexOf;

		m_path = m_path[min(m_nextEntry, $) .. $];
		m_absolute = false;

		final switch (m_type) {
			case PathType.posix, PathType.inet:
				auto idx = m_path.indexOf('/');
				m_nextEntry = idx >= 0 ? idx+1 : m_path.length;
				break;
			case PathType.windows:
				auto idx = m_path.indexOf('\\');
				auto idx2 = m_path[0 .. idx >= 0 ? idx : $].indexOf('/');
				m_nextEntry = idx2 >= 0 ? idx2+1 : idx >= 0 ? idx+1 : m_path.length;
				break;
		}
	}

	Path parentPath()
	@nogc {
		import std.string : lastIndexOf;
		auto idx = m_path.lastIndexOf('/');
		version (Windows) {
			auto idx2 = m_path.lastIndexOf('\\');
			if (idx2 > idx) idx = idx2;
		}
		// FIXME: handle Windows root path cases
		static const Exception e = new Exception("Path has no parent path");
		if (idx <= 0) throw e;
		return Path(m_path[0 .. idx+1]);
	}

	void normalize()
	{
		import std.array : join;

		auto ews = this.endsWithSlash;

		PathEntry[] newnodes;
		foreach (n; this[]) {
			switch(n.toString()){
				default: newnodes ~= n; break;
				case "", ".": break;
				case "..":
					enforce(!this.absolute || newnodes.length > 0, "Path goes below root node.");
					if( newnodes.length > 0 && newnodes[$-1] != ".." ) newnodes = newnodes[0 .. $-1];
					else newnodes ~= n;
					break;
			}
		}

		final switch (m_type) {
			case PathType.posix, PathType.inet:
				m_path = newnodes.map!(n => n.toString()).join('/');
				if (m_absolute) m_path = '/' ~ m_path;
				if (ews) m_path ~= '/';
				setupPath();
				break;
			case PathType.windows:
				m_path = newnodes.map!(n => n.toString()).join('\\');
				if (ews) m_path ~= '\\';
				setupPath();
				break;
		}
	}

	string toString() const nothrow @nogc { return m_path; }

	string toString(PathType type) const nothrow {
		import std.array : join;

		if (m_type == type) return m_path;
		if (type == PathType.windows) {
			return this[].map!(p => p.toString()).join('\\');
		} else {
			if (m_type == PathType.windows) {
				if (m_absolute) return '/' ~ this[].map!(n => n.toString()).join('/');
				else return this[].map!(n => n.toString()).join('/');
			} else return m_path;
		}
	}

	string toNativeString() const nothrow { return toString(PathType.native); }

	Path opSlice() const nothrow @nogc { return this; }

	Path opSlice(size_t from, size_t to)
	const nothrow @nogc {
		Path ret = this;
		foreach (i; 0 .. from) ret.popFront();
		auto rs = ret.toString();
		foreach (i; from .. to) ret.popFront();
		return Path(rs[0 .. $-ret.toString().length], m_type);
	}

	size_t opDollar() const nothrow @nogc { return m_length; }

	PathEntry opIndex(size_t idx) const nothrow @nogc { auto ret = this[]; ret.popFrontExactly(idx); return ret.front; }

	Path opBinary(string op : "~")(string subpath) nothrow { return this ~ Path(subpath); }
	Path opBinary(string op : "~")(Path subpath) nothrow {
		assert(!subpath.absolute || m_path.length == 0, "Cannot append absolute path.");

		if (this.endsWithSlash)
			return Path(m_path ~ subpath.m_path, m_type);
		if (!m_path.length) return subpath;
		
		final switch (m_type) {
			case PathType.inet, PathType.posix:
				return Path(m_path ~ '/' ~ subpath.m_path, m_type);
			case PathType.windows:
				return Path(m_path ~ '\\' ~ subpath.m_path, m_type);
		}
	}
	
	Path opBinary(string op : "~", R)(R entries) nothrow
		if (!is(R == Path) && isInputRange!R && is(ElementType!R == PathEntry))
	{
		import std.array : join;

		final switch (m_type) {
			case PathType.inet, PathType.posix:
				auto rpath = entries.map!(e => e.toString()).join('/');
				if (this.empty) return Path(rpath, m_type);
				if (this.endsWithSlash) return Path(m_path ~ rpath, m_type);
				return Path(m_path ~ '/' ~ rpath, m_type);
			case PathType.windows:
				auto rpath = entries.map!(e => e.toString()).join('\\');
				if (this.empty) return Path(rpath, m_type);
				if (this.endsWithSlash) return Path(m_path ~ rpath, m_type);
				return Path(m_path ~ '\\' ~ rpath, m_type);
		}
	}

	void opOpAssign(string op : "~", T)(T op) { this = this ~ op; }

	bool opEquals(Path other) const @nogc { import std.algorithm.comparison : equal; return this[].equal(other); }

	private void setupPath()
	nothrow @nogc {
		auto ap = getAbsolutePrefix(m_path, type);
		if (ap.length) {
			m_nextEntry = ap.length;
			m_absolute = true;
		} else {
			m_nextEntry = 0;
			popFront();
		}

		auto pr = this;
		while (!pr.empty) {
			m_length++;
			pr.popFront();
		}
	}
}

unittest {
	import std.algorithm.comparison : equal;

	with (PathType) {
		assert(Path("hello/world", posix).equal([PathEntry("hello/", posix), PathEntry("world", posix)]));
		assert(Path("/hello/world/", posix).equal([PathEntry("/", posix), PathEntry("hello/", posix), PathEntry("world/", posix)]));
		assert(Path("hello\\world", posix).equal([PathEntry("hello\\world", posix)]));
		assert(Path("hello/world", windows).equal([PathEntry("hello/", windows), PathEntry("world", windows)]));
		assert(Path("/hello/world/", windows).equal([PathEntry("/", windows), PathEntry("hello/", windows), PathEntry("world/", windows)]));
		assert(Path("hello\\w/orld", windows).equal([PathEntry("hello\\", windows), PathEntry("w/", windows), PathEntry("orld", windows)]));
		assert(Path("hello/w\\orld", windows).equal([PathEntry("hello/", windows), PathEntry("w\\", windows), PathEntry("orld", windows)]));
	}
}

unittest
{
	import std.algorithm.comparison : equal;

	{
		auto unc = "\\\\server\\share\\path";
		auto uncp = Path(unc, PathType.windows);
		assert(uncp.absolute);
		uncp.normalize();
		version(Windows) assert(uncp.toNativeString() == unc);
		assert(uncp.absolute);
		assert(!uncp.endsWithSlash);
	}

	{
		auto abspath = "/test/path/";
		auto abspathp = Path(abspath, PathType.posix);
		assert(abspathp.toString() == abspath);
		version(Windows) {} else assert(abspathp.toNativeString() == abspath);
		assert(abspathp.absolute);
		assert(abspathp.endsWithSlash);
		assert(abspathp.length == 3);
		assert(abspathp[0] == "");
		assert(abspathp[1] == "test");
		assert(abspathp[2] == "path");
	}

	{
		auto relpath = "test/path/";
		auto relpathp = Path(relpath, PathType.posix);
		assert(relpathp.toString() == relpath);
		version(Windows) assert(relpathp.toNativeString() == "test\\path\\");
		else assert(relpathp.toNativeString() == relpath);
		assert(!relpathp.absolute);
		assert(relpathp.endsWithSlash);
		assert(relpathp.length == 2);
		assert(relpathp[0] == "test");
		assert(relpathp[1] == "path");
	}

	{
		auto winpath = "C:\\windows\\test";
		auto winpathp = Path(winpath, PathType.windows);
		assert(winpathp.toString() == "C:\\windows\\test");
		assert(winpathp.toString(PathType.posix) == "/C:/windows/test");
		version(Windows) assert(winpathp.toNativeString() == winpath);
		else assert(winpathp.toNativeString() == "/C:/windows/test");
		assert(winpathp.absolute);
		assert(!winpathp.endsWithSlash);
		assert(winpathp.length == 3);
		assert(winpathp[0] == "C:");
		assert(winpathp[1] == "windows");
		assert(winpathp[2] == "test");
	}

	{
		auto dotpath = "/test/../test2/././x/y";
		auto dotpathp = Path(dotpath, PathType.posix);
		assert(dotpathp.toString() == "/test/../test2/././x/y");
		dotpathp.normalize();
		assert(dotpathp.toString() == "/test2/x/y", dotpathp.toString());
	}

	{
		auto dotpath = "/test/..////test2//./x/y";
		auto dotpathp = Path(dotpath, PathType.posix);
		assert(dotpathp.toString() == "/test/..////test2//./x/y");
		dotpathp.normalize();
		assert(dotpathp.toString() == "/test2/x/y");
	}

	{
		auto parentpath = "/path/to/parent";
		auto parentpathp = Path(parentpath, PathType.posix);
		auto subpath = "/path/to/parent/sub/";
		auto subpathp = Path(subpath, PathType.posix);
		auto subpath_rel = "sub/";
		assert(subpathp.relativeTo(parentpathp).toString() == subpath_rel);
		auto subfile = "/path/to/parent/child";
		auto subfilep = Path(subfile, PathType.posix);
		auto subfile_rel = "child";
		assert(subfilep.relativeTo(parentpathp).toString() == subfile_rel);
	}

	{ // relative paths across Windows devices are not allowed
		auto p1 = Path("\\\\server\\share", PathType.windows); assert(p1.absolute);
		auto p2 = Path("\\\\server\\othershare", PathType.windows); assert(p2.absolute);
		auto p3 = Path("\\\\otherserver\\share", PathType.windows); assert(p3.absolute);
		auto p4 = Path("C:\\somepath", PathType.windows); assert(p4.absolute);
		auto p5 = Path("C:\\someotherpath", PathType.windows); assert(p5.absolute);
		auto p6 = Path("D:\\somepath", PathType.windows); assert(p6.absolute);
		assert(p4.relativeTo(p5) == Path("../somepath", PathType.windows));
		assert(p4.relativeTo(p6) == Path("C:\\somepath", PathType.windows));
		assert(p4.relativeTo(p1) == Path("C:\\somepath", PathType.windows));
		assert(p1.relativeTo(p2) == Path("../share", PathType.windows));
		assert(p1.relativeTo(p3) == Path("\\\\server\\share", PathType.windows));
		assert(p1.relativeTo(p4) == Path("\\\\server\\share", PathType.windows));
	}

	{ // relative path, trailing slash
		auto p1 = Path("/some/path", PathType.posix);
		auto p2 = Path("/some/path/", PathType.posix);
		assert(p1.relativeTo(p1).toString() == "");
		assert(p1.relativeTo(p2).toString() == "");
		assert(p2.relativeTo(p2).toString() == "./");
	}

	assert(Path("").empty);
	assert(Path("a/b/c")[1 .. 3].map!(p => p.toString()).equal(["b", "c"]));

	assert(Path("/", PathType.posix) ~ Path("foo/bar") == Path("/foo/bar"));
	assert(Path("", PathType.posix) ~ Path("foo/bar") == Path("foo/bar"));
	assert(Path("foo", PathType.posix) ~ Path("bar") == Path("foo/bar"));
	assert(Path("foo/", PathType.posix) ~ Path("bar") == Path("foo/bar"));
}


struct PathEntry {
	import std.string : cmp;

	@safe pure nothrow:

	private {
		string m_name;
		bool m_hasSeparator;
	}

	this(string str, PathType pt, bool is_absolute_prefix = false)
	@nogc {
		import std.algorithm.searching : any;

		m_name = str;

		if (m_name.length > 0) {
			final switch (pt) {
				case PathType.inet, PathType.posix:
					m_hasSeparator = m_name[$-1] == '/';
					break;
				case PathType.windows:
					m_hasSeparator = m_name[$-1] == '/' || m_name[$-1] == '\\';
					break;
			}
		}

		debug if (!is_absolute_prefix)
			foreach (char ch; str[0 .. $-min(1, $)]) {
				assert(ch != '/', "Invalid path entry.");
				if (pt == PathType.windows)
					assert(ch != '\\', "Invalid Windows path entry.");
			}
	}

	alias toString this;

	string toString() const @nogc { return m_name[0 .. m_hasSeparator ? $-1 : $]; }

	string toFullString() const @nogc { return m_name; }

	Path opBinary(string OP)(PathEntry rhs) const if( OP == "~" ) { return Path([this, rhs], false); }

	bool opEquals(ref const PathEntry rhs) const @nogc { return this == rhs.toString(); }
	bool opEquals(PathEntry rhs) const @nogc { return this == rhs.toString(); }
	bool opEquals(string rhs) const @nogc { return this.toString() == rhs; }
	int opCmp(ref const PathEntry rhs) const @nogc { return this.toString().cmp(rhs.toString()); }
	int opCmp(string rhs) const @nogc { return this.toString().cmp(rhs); }
}

enum PathType {
	posix,
	windows,
	inet,
	native = isWindows ? windows : posix
}

private string getAbsolutePrefix(string path, PathType type)
@safe nothrow @nogc {
	import std.string : indexOfAny;
	import std.algorithm.comparison : among;

	final switch (type) {
		case PathType.posix, PathType.inet:
			if (path.length > 0 && path[0] == '/')
				return path[0 .. 1];
			return null;
		case PathType.windows:
			if (path.length >= 2 && path[0 .. 2] == "\\\\")
				return path[0 .. 2];
			foreach (i; 1 .. path.length)
				if (path[i].among!('/', '\\')) {
					if (path[i-1] == ':')
						return path[0 .. i+1];
					break;
				}
			return null;
	}
}

unittest {
	assert(getAbsolutePrefix("/", PathType.posix) == "/");
	assert(getAbsolutePrefix("/test", PathType.posix) == "/");
	assert(getAbsolutePrefix("/test/", PathType.posix) == "/");
	assert(getAbsolutePrefix("test/", PathType.posix) == "");
	assert(getAbsolutePrefix("", PathType.posix) == "");
	assert(getAbsolutePrefix("./", PathType.posix) == "");

	assert(getAbsolutePrefix("/", PathType.inet) == "/");
	assert(getAbsolutePrefix("/test", PathType.inet) == "/");
	assert(getAbsolutePrefix("/test/", PathType.inet) == "/");
	assert(getAbsolutePrefix("test/", PathType.inet) == "");
	assert(getAbsolutePrefix("", PathType.inet) == "");
	assert(getAbsolutePrefix("./", PathType.inet) == "");

	assert(getAbsolutePrefix("/test", PathType.windows) == "");
	assert(getAbsolutePrefix("\\test", PathType.windows) == "");
	assert(getAbsolutePrefix("C:\\", PathType.windows) == "C:\\");
	assert(getAbsolutePrefix("C:\\test", PathType.windows) == "C:\\");
	assert(getAbsolutePrefix("C:\\test\\", PathType.windows) == "C:\\");
	assert(getAbsolutePrefix("C:/", PathType.windows) == "C:/");
	assert(getAbsolutePrefix("C:/test", PathType.windows) == "C:/");
	assert(getAbsolutePrefix("C:/test/", PathType.windows) == "C:/");
	assert(getAbsolutePrefix("\\\\server", PathType.windows) == "\\\\");
	assert(getAbsolutePrefix("\\\\server\\", PathType.windows) == "\\\\");
	assert(getAbsolutePrefix("\\\\.\\", PathType.windows) == "\\\\");
	assert(getAbsolutePrefix("\\\\?\\", PathType.windows) == "\\\\");
}

version (Windows) private enum isWindows = true;
else private enum isWindows = false;

/**
	File handling functions and types.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.file;

//public import vibe.core.stream;
//public import vibe.inet.url;
import vibe.core.path;

import core.stdc.stdio;
import core.sys.posix.unistd;
import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import std.conv : octal;
import vibe.core.log;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.string;


version(Posix){
	private extern(C) int mkstemps(char* templ, int suffixlen);
}


/**
	Opens a file stream with the specified mode.
*/
FileStream openFile(Path path, FileMode mode = FileMode.read)
{
	assert(false);
	//return eventDriver.openFile(path, mode);
}
/// ditto
FileStream openFile(string path, FileMode mode = FileMode.read)
{
	return openFile(Path(path), mode);
}


/**
	Read a whole file into a buffer.

	If the supplied buffer is large enough, it will be used to store the
	contents of the file. Otherwise, a new buffer will be allocated.

	Params:
		path = The path of the file to read
		buffer = An optional buffer to use for storing the file contents
*/
ubyte[] readFile(Path path, ubyte[] buffer = null, size_t max_size = size_t.max)
{
	auto fil = openFile(path);
	scope (exit) fil.close();
	enforce(fil.size <= max_size, "File is too big.");
	auto sz = cast(size_t)fil.size;
	auto ret = sz <= buffer.length ? buffer[0 .. sz] : new ubyte[sz];
	fil.read(ret);
	return ret;
}
/// ditto
ubyte[] readFile(string path, ubyte[] buffer = null, size_t max_size = size_t.max)
{
	return readFile(Path(path), buffer, max_size);
}


/**
	Write a whole file at once.
*/
void writeFile(Path path, in ubyte[] contents)
{
	auto fil = openFile(path, FileMode.createTrunc);
	scope (exit) fil.close();
	fil.write(contents);
}
/// ditto
void writeFile(string path, in ubyte[] contents)
{
	writeFile(Path(path), contents);
}

/**
	Convenience function to append to a file.
*/
void appendToFile(Path path, string data) {
	auto fil = openFile(path, FileMode.append);
	scope(exit) fil.close();
	fil.write(data);
}
/// ditto
void appendToFile(string path, string data)
{
	appendToFile(Path(path), data);
}

/**
	Read a whole UTF-8 encoded file into a string.

	The resulting string will be sanitized and will have the
	optional byte order mark (BOM) removed.
*/
string readFileUTF8(Path path)
{
	import vibe.internal.string;

	return stripUTF8Bom(sanitizeUTF8(readFile(path)));
}
/// ditto
string readFileUTF8(string path)
{
	return readFileUTF8(Path(path));
}


/**
	Write a string into a UTF-8 encoded file.

	The file will have a byte order mark (BOM) prepended.
*/
void writeFileUTF8(Path path, string contents)
{
	static immutable ubyte[] bom = [0xEF, 0xBB, 0xBF];
	auto fil = openFile(path, FileMode.createTrunc);
	scope (exit) fil.close();
	fil.write(bom);
	fil.write(contents);
}

/**
	Creates and opens a temporary file for writing.
*/
FileStream createTempFile(string suffix = null)
{
	version(Windows){
		import std.conv : to;
		char[L_tmpnam] tmp;
		tmpnam(tmp.ptr);
		auto tmpname = to!string(tmp.ptr);
		if( tmpname.startsWith("\\") ) tmpname = tmpname[1 .. $];
		tmpname ~= suffix;
		return openFile(tmpname, FileMode.createTrunc);
	} else {
		enum pattern ="/tmp/vtmp.XXXXXX";
		scope templ = new char[pattern.length+suffix.length+1];
		templ[0 .. pattern.length] = pattern;
		templ[pattern.length .. $-1] = (suffix)[];
		templ[$-1] = '\0';
		assert(suffix.length <= int.max);
		auto fd = mkstemps(templ.ptr, cast(int)suffix.length);
		enforce(fd >= 0, "Failed to create temporary file.");
		assert(false);
		//return eventDriver.adoptFile(fd, Path(templ[0 .. $-1].idup), FileMode.createTrunc);
	}
}

/**
	Moves or renames a file.

	Params:
		from = Path to the file/directory to move/rename.
		to = The target path
		copy_fallback = Determines if copy/remove should be used in case of the
			source and destination path pointing to different devices.
*/
void moveFile(Path from, Path to, bool copy_fallback = false)
{
	moveFile(from.toNativeString(), to.toNativeString(), copy_fallback);
}
/// ditto
void moveFile(string from, string to, bool copy_fallback = false)
{
	if (!copy_fallback) {
		std.file.rename(from, to);
	} else {
		try {
			std.file.rename(from, to);
		} catch (FileException e) {
			std.file.copy(from, to);
			std.file.remove(from);
		}
	}
}

/**
	Copies a file.

	Note that attributes and time stamps are currently not retained.

	Params:
		from = Path of the source file
		to = Path for the destination file
		overwrite = If true, any file existing at the destination path will be
			overwritten. If this is false, an exception will be thrown should
			a file already exist at the destination path.

	Throws:
		An Exception if the copy operation fails for some reason.
*/
void copyFile(Path from, Path to, bool overwrite = false)
{
	{
		auto src = openFile(from, FileMode.read);
		scope(exit) src.close();
		enforce(overwrite || !existsFile(to), "Destination file already exists.");
		auto dst = openFile(to, FileMode.createTrunc);
		scope(exit) dst.close();
		dst.write(src);
	}

	// TODO: retain attributes and time stamps
}
/// ditto
void copyFile(string from, string to)
{
	copyFile(Path(from), Path(to));
}

/**
	Removes a file
*/
void removeFile(Path path)
{
	removeFile(path.toNativeString());
}
/// ditto
void removeFile(string path)
{
	std.file.remove(path);
}

/**
	Checks if a file exists
*/
bool existsFile(Path path) nothrow
{
	return existsFile(path.toNativeString());
}
/// ditto
bool existsFile(string path) nothrow
{
	// This was *annotated* nothrow in 2.067.
	static if (__VERSION__ < 2067)
		scope(failure) assert(0, "Error: existsFile should never throw");
	return std.file.exists(path);
}

/** Stores information about the specified file/directory into 'info'

	Throws: A `FileException` is thrown if the file does not exist.
*/
FileInfo getFileInfo(Path path)
{
	auto ent = DirEntry(path.toNativeString());
	return makeFileInfo(ent);
}
/// ditto
FileInfo getFileInfo(string path)
{
	return getFileInfo(Path(path));
}

/**
	Creates a new directory.
*/
void createDirectory(Path path)
{
	mkdir(path.toNativeString());
}
/// ditto
void createDirectory(string path)
{
	createDirectory(Path(path));
}

/**
	Enumerates all files in the specified directory.
*/
void listDirectory(Path path, scope bool delegate(FileInfo info) del)
{
	foreach( DirEntry ent; dirEntries(path.toNativeString(), SpanMode.shallow) )
		if( !del(makeFileInfo(ent)) )
			break;
}
/// ditto
void listDirectory(string path, scope bool delegate(FileInfo info) del)
{
	listDirectory(Path(path), del);
}
/// ditto
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(Path path)
{
	int iterator(scope int delegate(ref FileInfo) del){
		int ret = 0;
		listDirectory(path, (fi){
			ret = del(fi);
			return ret == 0;
		});
		return ret;
	}
	return &iterator;
}
/// ditto
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(string path)
{
	return iterateDirectory(Path(path));
}

/**
	Starts watching a directory for changes.
*/
DirectoryWatcher watchDirectory(Path path, bool recursive = true)
{
	assert(false);
	//return eventDriver.watchDirectory(path, recursive);
}
// ditto
DirectoryWatcher watchDirectory(string path, bool recursive = true)
{
	return watchDirectory(Path(path), recursive);
}

/**
	Returns the current working directory.
*/
Path getWorkingDirectory()
{
	return Path(std.file.getcwd());
}


/** Contains general information about a file.
*/
struct FileInfo {
	/// Name of the file (not including the path)
	string name;

	/// Size of the file (zero for directories)
	ulong size;

	/// Time of the last modification
	SysTime timeModified;

	/// Time of creation (not available on all operating systems/file systems)
	SysTime timeCreated;

	/// True if this is a symlink to an actual file
	bool isSymlink;

	/// True if this is a directory or a symlink pointing to a directory
	bool isDirectory;
}

/**
	Specifies how a file is manipulated on disk.
*/
enum FileMode {
	/// The file is opened read-only.
	read,
	/// The file is opened for read-write random access.
	readWrite,
	/// The file is truncated if it exists or created otherwise and then opened for read-write access.
	createTrunc,
	/// The file is opened for appending data to it and created if it does not exist.
	append
}

/**
	Accesses the contents of a file as a stream.
*/
struct FileStream {
	import std.algorithm.comparison : min;
	import vibe.core.core : yield;
	import core.stdc.errno;

	version (Windows) {} else
	{
		enum O_BINARY = 0;
	}

	private {
		int m_fileDescriptor;
		Path m_path;
		ulong m_size;
		ulong m_ptr = 0;
		FileMode m_mode;
		bool m_ownFD = true;
	}

	this(Path path, FileMode mode)
	{
		auto pathstr = path.toNativeString();
		final switch(mode){
			case FileMode.read:
				m_fileDescriptor = open(pathstr.toStringz(), O_RDONLY|O_BINARY);
				break;
			case FileMode.readWrite:
				m_fileDescriptor = open(pathstr.toStringz(), O_RDWR|O_BINARY);
				break;
			case FileMode.createTrunc:
				m_fileDescriptor = open(pathstr.toStringz(), O_RDWR|O_CREAT|O_TRUNC|O_BINARY, octal!644);
				break;
			case FileMode.append:
				m_fileDescriptor = open(pathstr.toStringz(), O_WRONLY|O_CREAT|O_APPEND|O_BINARY, octal!644);
				break;
		}
		if( m_fileDescriptor < 0 )
			//throw new Exception(format("Failed to open '%s' with %s: %d", pathstr, cast(int)mode, errno));
			throw new Exception("Failed to open file '"~pathstr~"'.");

		this(m_fileDescriptor, path, mode);
	}

	this(int fd, Path path, FileMode mode)
	{
		assert(fd >= 0);
		m_fileDescriptor = fd;
		m_path = path;
		m_mode = mode;

		version(linux){
			// stat_t seems to be defined wrong on linux/64
			m_size = lseek(m_fileDescriptor, 0, SEEK_END);
		} else {
			stat_t st;
			fstat(m_fileDescriptor, &st);
			m_size = st.st_size;

			// (at least) on windows, the created file is write protected
			version(Windows){
				if( mode == FileMode.createTrunc )
					chmod(path.toNativeString().toStringz(), S_IREAD|S_IWRITE);
			}
		}
		lseek(m_fileDescriptor, 0, SEEK_SET);

		logDebug("opened file %s with %d bytes as %d", path.toNativeString(), m_size, m_fileDescriptor);
	}

	~this()
	{
		close();
	}

	@property int fd() { return m_fileDescriptor; }

	/// The path of the file.
	@property Path path() const { return m_path; }

	/// Determines if the file stream is still open
	@property bool isOpen() const { return m_fileDescriptor >= 0; }
	@property ulong size() const { return m_size; }
	@property bool readable() const { return m_mode != FileMode.append; }
	@property bool writable() const { return m_mode != FileMode.read; }

	void takeOwnershipOfFD()
	{
		enforce(m_ownFD);
		m_ownFD = false;
	}

	void seek(ulong offset)
	{
		version (Win32) {
			enforce(offset <= off_t.max, "Cannot seek above 4GB on Windows x32.");
			auto pos = lseek(m_fileDescriptor, cast(off_t)offset, SEEK_SET);
		} else auto pos = lseek(m_fileDescriptor, offset, SEEK_SET);
		enforce(pos == offset, "Failed to seek in file.");
		m_ptr = offset;
	}

	ulong tell() { return m_ptr; }

	/// Closes the file handle.
	void close()
	{
		if( m_fileDescriptor != -1 && m_ownFD ){
			.close(m_fileDescriptor);
			m_fileDescriptor = -1;
		}
	}

	@property bool empty() const { assert(this.readable); return m_ptr >= m_size; }
	@property ulong leastSize() const { assert(this.readable); return m_size - m_ptr; }
	@property bool dataAvailableForRead() { return true; }

	const(ubyte)[] peek()
	{
		return null;
	}

	void read(ubyte[] dst)
	{
		assert(this.readable);
		while (dst.length > 0) {
			enforce(dst.length <= leastSize);
			auto sz = min(dst.length, 4096);
			enforce(.read(m_fileDescriptor, dst.ptr, cast(int)sz) == sz, "Failed to read data from disk.");
			dst = dst[sz .. $];
			m_ptr += sz;
			yield();
		}
	}

	void write(in ubyte[] bytes_)
	{
		const(ubyte)[] bytes = bytes_;
		assert(this.writable);
		while (bytes.length > 0) {
			auto sz = min(bytes.length, 4096);
			auto ret = .write(m_fileDescriptor, bytes.ptr, cast(int)sz);
			import std.format : format;
			enforce(ret == sz, format("Failed to write data to disk. %s %s %s %s", sz, errno, ret, m_fileDescriptor));
			bytes = bytes[sz .. $];
			m_ptr += sz;
			yield();
		}
	}

	void write(InputStream)(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}

	void flush()
	{
		assert(this.writable);
	}

	void finalize()
	{
		flush();
	}
}

private void writeDefault(OutputStream, InputStream)(ref OutputStream dst, InputStream stream, ulong nbytes = 0)
{
	assert(false);
	/*
	static struct Buffer { ubyte[64*1024] bytes = void; }
	auto bufferobj = FreeListRef!(Buffer, false)();
	auto buffer = bufferobj.bytes[];

	//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
	if (nbytes == 0) {
		while (!stream.empty) {
			size_t chunk = min(stream.leastSize, buffer.length);
			assert(chunk > 0, "leastSize returned zero for non-empty stream.");
			//logTrace("read pipe chunk %d", chunk);
			stream.read(buffer[0 .. chunk]);
			dst.write(buffer[0 .. chunk]);
		}
	} else {
		while (nbytes > 0) {
			size_t chunk = min(nbytes, buffer.length);
			//logTrace("read pipe chunk %d", chunk);
			stream.read(buffer[0 .. chunk]);
			dst.write(buffer[0 .. chunk]);
			nbytes -= chunk;
		}
	}
	*/
}


/**
	Interface for directory watcher implementations.

	Directory watchers monitor the contents of a directory (wither recursively or non-recursively)
	for changes, such as file additions, deletions or modifications.
*/
interface DirectoryWatcher {
	/// The path of the watched directory
	@property Path path() const;

	/// Indicates if the directory is watched recursively
	@property bool recursive() const;

	/** Fills the destination array with all changes that occurred since the last call.

		The function will block until either directory changes have occurred or until the
		timeout has elapsed. Specifying a negative duration will cause the function to
		wait without a timeout.

		Params:
			dst = The destination array to which the changes will be appended
			timeout = Optional timeout for the read operation

		Returns:
			If the call completed successfully, true is returned.
	*/
	bool readChanges(ref DirectoryChange[] dst, Duration timeout = dur!"seconds"(-1));
}


/** Specifies the kind of change in a watched directory.
*/
enum DirectoryChangeType {
	/// A file or directory was added
	added,
	/// A file or directory was deleted
	removed,
	/// A file or directory was modified
	modified
}


/** Describes a single change in a watched directory.
*/
struct DirectoryChange {
	/// The type of change
	DirectoryChangeType type;

	/// Path of the file/directory that was changed
	Path path;
}


private FileInfo makeFileInfo(DirEntry ent)
{
	FileInfo ret;
	ret.name = baseName(ent.name);
	if( ret.name.length == 0 ) ret.name = ent.name;
	assert(ret.name.length > 0);
	ret.size = ent.size;
	ret.timeModified = ent.timeLastModified;
	version(Windows) ret.timeCreated = ent.timeCreated;
	else ret.timeCreated = ent.timeLastModified;
	ret.isSymlink = ent.isSymlink;
	ret.isDirectory = ent.isDir;
	return ret;
}

/**
	TCP/UDP connection and server handling.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.net;

import eventcore.core;
import std.exception : enforce;
import std.format : format;
import std.functional : toDelegate;
import std.socket : AddressFamily, UnknownAddress;
import vibe.core.log;
import vibe.core.stream;
import vibe.internal.async;
import core.time : Duration;

@safe:


/**
	Resolves the given host name/IP address string.

	Setting use_dns to false will only allow IP address strings but also guarantees
	that the call will not block.
*/
NetworkAddress resolveHost(string host, AddressFamily address_family = AddressFamily.UNSPEC, bool use_dns = true)
{
	return resolveHost(host, cast(ushort)address_family, use_dns);
}
/// ditto
NetworkAddress resolveHost(string host, ushort address_family, bool use_dns = true)
{
	import std.socket : parseAddress;
	version (Windows) import std.c.windows.winsock : sockaddr_in, sockaddr_in6;
	else import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6;

	enforce(host.length > 0, "Host name must not be empty.");
	if (host[0] == ':' || host[0] >= '0' && host[0] <= '9') {
		auto addr = parseAddress(host);
		enforce(address_family == AddressFamily.UNSPEC || addr.addressFamily == address_family);
		NetworkAddress ret;
		ret.family = addr.addressFamily;
		switch (addr.addressFamily) with(AddressFamily) {
			default: throw new Exception("Unsupported address family");
			case INET: *ret.sockAddrInet4 = () @trusted { return *cast(sockaddr_in*)addr.name; } (); break;
			case INET6: *ret.sockAddrInet6 = () @trusted { return *cast(sockaddr_in6*)addr.name; } (); break;
		}
		return ret;
	} else {
		enforce(use_dns, "Malformed IP address string.");
		auto res = asyncAwait!(DNSLookupCallback,
			cb => eventDriver.dns.lookupHost(host, cb),
			(cb, id) => eventDriver.dns.cancelLookup(id)
		);
		enforce(res[1] == DNSStatus.ok && res[2].length > 0, "Failed to lookup host '"~host~"'.");
		return NetworkAddress(res[2][0]);
	}
}


/**
	Starts listening on the specified port.

	'connection_callback' will be called for each client that connects to the
	server socket. Each new connection gets its own fiber. The stream parameter
	then allows to perform blocking I/O on the client socket.

	The address parameter can be used to specify the network
	interface on which the server socket is supposed to listen for connections.
	By default, all IPv4 and IPv6 interfaces will be used.
*/
TCPListener[] listenTCP(ushort port, TCPConnectionDelegate connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	TCPListener[] ret;
	try ret ~= listenTCP(port, connection_callback, "::", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"::\": %s", e.msg);
	try ret ~= listenTCP(port, connection_callback, "0.0.0.0", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"0.0.0.0\": %s", e.msg);
	enforce(ret.length > 0, format("Failed to listen on all interfaces on port %s", port));
	return ret;
}
/// ditto
TCPListener listenTCP(ushort port, TCPConnectionDelegate connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	auto addr = resolveHost(address);
	addr.port = port;
	assert(options == TCPListenOptions.defaults, "TODO");
	auto sock = eventDriver.sockets.listenStream(addr.toUnknownAddress,
		(StreamListenSocketFD ls, StreamSocketFD s, scope RefAddress addr) @safe nothrow {
			import vibe.core.core : runTask;
			auto conn = TCPConnection(s, addr);
			runTask(connection_callback, conn);
		});
	return TCPListener(sock);
}

/**
	Starts listening on the specified port.

	This function is the same as listenTCP but takes a function callback instead of a delegate.
*/
TCPListener[] listenTCP_s(ushort port, TCPConnectionFunction connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	return listenTCP(port, toDelegate(connection_callback), options);
}
/// ditto
TCPListener listenTCP_s(ushort port, TCPConnectionFunction connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	return listenTCP(port, toDelegate(connection_callback), address, options);
}

/**
	Establishes a connection to the given host/port.
*/
TCPConnection connectTCP(string host, ushort port, string bind_interface = null, ushort bind_port = 0)
{
	NetworkAddress addr = resolveHost(host);
	addr.port = port;
	if (addr.family != AddressFamily.UNIX)
		addr.port = port;

	NetworkAddress bind_address;
	if (bind_interface.length) bind_address = resolveHost(bind_interface, addr.family);
	else {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
	}
	if (addr.family != AddressFamily.UNIX)
		bind_address.port = bind_port;

	return connectTCP(addr, bind_address);
}
/// ditto
TCPConnection connectTCP(NetworkAddress addr, NetworkAddress bind_address = anyAddress)
{
	import std.conv : to;

	if (bind_address.family == AddressFamily.UNSPEC) {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
		if (bind_address.family != AddressFamily.UNIX)
			bind_address.port = 0;
	}
	enforce(addr.family == bind_address.family, "Destination address and bind address have different address families.");

	return () @trusted { // scope
		scope uaddr = new RefAddress(addr.sockAddr, addr.sockAddrLen);
		scope baddr = new RefAddress(bind_address.sockAddr, bind_address.sockAddrLen);
		
		// FIXME: make this interruptible
		auto result = asyncAwaitUninterruptible!(ConnectCallback, 
			cb => eventDriver.sockets.connectStream(uaddr, baddr, cb)
			//cb => eventDriver.sockets.cancelConnect(cb)
		);
		enforce(result[1] == ConnectStatus.connected, "Failed to connect to "~addr.toString()~": "~result[1].to!string);

		return TCPConnection(result[0], uaddr);
	} ();
}


/**
	Creates a bound UDP socket suitable for sending and receiving packets.
*/
UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0")
{
	auto addr = resolveHost(bind_address, AddressFamily.UNSPEC, false);
	addr.port = port;
	return UDPConnection(addr);
}

NetworkAddress anyAddress()
{
	NetworkAddress ret;
	ret.family = AddressFamily.UNSPEC;
	return ret;
}


/// Callback invoked for incoming TCP connections.
@safe nothrow alias TCPConnectionDelegate = void delegate(TCPConnection stream);
/// ditto
@safe nothrow alias TCPConnectionFunction = void delegate(TCPConnection stream);


/**
	Represents a network/socket address.
*/
struct NetworkAddress {
	import std.algorithm.comparison : max;
	import std.socket : Address;

	version (Windows) import core.sys.windows.winsock2;
	else import core.sys.posix.netinet.in_;

	@safe:

	private union {
		sockaddr addr;
		sockaddr_in addr_ip4;
		sockaddr_in6 addr_ip6;
	}

	enum socklen_t sockAddrMaxLen = max(addr.sizeof, addr_ip6.sizeof);


	this(Address addr)
		@trusted
	{
		assert(addr !is null);
		switch (addr.addressFamily) {
			default: throw new Exception("Unsupported address family.");
			case AddressFamily.INET:
				this.family = AddressFamily.INET;
				assert(addr.nameLen >= sockaddr_in.sizeof);
				*this.sockAddrInet4 = *cast(sockaddr_in*)addr.name;
				break;
			case AddressFamily.INET6:
				this.family = AddressFamily.INET6;
				assert(addr.nameLen >= sockaddr_in6.sizeof);
				*this.sockAddrInet6 = *cast(sockaddr_in6*)addr.name;
				break;
		}
	}

	/** Family of the socket address.
	*/
	@property ushort family() const pure nothrow { return addr.sa_family; }
	/// ditto
	@property void family(AddressFamily val) pure nothrow { addr.sa_family = cast(ubyte)val; }
	/// ditto
	@property void family(ushort val) pure nothrow { addr.sa_family = cast(ubyte)val; }

	/** The port in host byte order.
	*/
	@property ushort port()
	const pure nothrow {
		ushort nport;
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: nport = addr_ip4.sin_port; break;
			case AF_INET6: nport = addr_ip6.sin6_port; break;
		}
		return () @trusted { return ntoh(nport); } ();
	}
	/// ditto
	@property void port(ushort val)
	pure nothrow {
		auto nport = () @trusted { return hton(val); } ();
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: addr_ip4.sin_port = nport; break;
			case AF_INET6: addr_ip6.sin6_port = nport; break;
		}
	}

	/** A pointer to a sockaddr struct suitable for passing to socket functions.
	*/
	@property inout(sockaddr)* sockAddr() inout pure nothrow { return &addr; }

	/** Size of the sockaddr struct that is returned by sockAddr().
	*/
	@property socklen_t sockAddrLen()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "sockAddrLen() called for invalid address family.");
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
		}
	}

	@property inout(sockaddr_in)* sockAddrInet4() inout pure nothrow
		in { assert (family == AF_INET); }
		body { return &addr_ip4; }

	@property inout(sockaddr_in6)* sockAddrInet6() inout pure nothrow
		in { assert (family == AF_INET6); }
		body { return &addr_ip6; }

	/** Returns a string representation of the IP address
	*/
	string toAddressString()
	const {
		import std.array : appender;
		auto ret = appender!string();
		ret.reserve(40);
		toAddressString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toAddressString(scope void delegate(const(char)[]) @safe sink)
	const {
		import std.array : appender;
		import std.format : formattedWrite;
		ubyte[2] _dummy = void; // Workaround for DMD regression in master

		switch (this.family) {
			default: assert(false, "toAddressString() called for invalid address family.");
			case AF_INET:
				ubyte[4] ip = () @trusted { return (cast(ubyte*)&addr_ip4.sin_addr.s_addr)[0 .. 4]; } ();
				sink.formattedWrite("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
				break;
			case AF_INET6:
				ubyte[16] ip = addr_ip6.sin6_addr.s6_addr;
				foreach (i; 0 .. 8) {
					if (i > 0) sink(":");
					_dummy[] = ip[i*2 .. i*2+2];
					sink.formattedWrite("%x", bigEndianToNative!ushort(_dummy));
				}
				break;
		}
	}

	/** Returns a full string representation of the address, including the port number.
	*/
	string toString()
	const {
		import std.array : appender;
		auto ret = appender!string();
		toString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toString(scope void delegate(const(char)[]) @safe sink)
	const {
		import std.format : formattedWrite;
		switch (this.family) {
			default: assert(false, "toString() called for invalid address family.");
			case AF_INET:
				toAddressString(sink);
				sink.formattedWrite(":%s", port);
				break;
			case AF_INET6:
				sink("[");
				toAddressString(sink);
				sink.formattedWrite("]:%s", port);
				break;
		}
	}

	UnknownAddress toUnknownAddress()
	const nothrow {
		auto ret = new UnknownAddress;
		toUnknownAddress(ret);
		return ret;
	}

	void toUnknownAddress(scope UnknownAddress addr)
	const nothrow {
		*addr.name = *this.sockAddr;
	}

	version(Have_libev) {}
	else {
		unittest {
			void test(string ip) {
				auto res = () @trusted { return resolveHost(ip, AF_UNSPEC, false); } ().toAddressString();
				assert(res == ip,
					   "IP "~ip~" yielded wrong string representation: "~res);
			}
			test("1.2.3.4");
			test("102:304:506:708:90a:b0c:d0e:f10");
		}
	}
}

/**
	Represents a single TCP connection.
*/
struct TCPConnection {
	@safe:

	import core.time : seconds;
	import vibe.internal.array : BatchBuffer;
	//static assert(isConnectionStream!TCPConnection);

	static struct Context {
		BatchBuffer!ubyte readBuffer;
		bool tcpNoDelay = false;
		bool keepAlive = false;
		Duration readTimeout = Duration.max;
		NetworkAddress remoteAddress;
		NetworkAddress localAddress;
		string remoteAddressString;
	}

	private {
		StreamSocketFD m_socket;
		Context* m_context;
	}

	private this(StreamSocketFD socket, scope RefAddress remote_address)
	nothrow {
		import std.exception : enforce;

		m_socket = socket;
		m_context = () @trusted { return &eventDriver.core.userData!Context(socket); } ();
		m_context.readBuffer.capacity = 4096;
		try m_context.remoteAddress = NetworkAddress(remote_address);
		catch (Exception e) { logWarn("Failed to get remote address for TCP connection: %s", e.msg); }
		scope laddr = new RefAddress(m_context.localAddress.sockAddr, m_context.localAddress.sockAddrMaxLen);
		try {
			enforce(eventDriver.sockets.getLocalAddress(socket, laddr), "Failed to query socket address.");
			m_context.localAddress = NetworkAddress(laddr);
		} catch (Exception e) { logWarn("Failed to get local address for TCP connection: %s", e.msg); }
	}

	this(this)
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.releaseRef(m_socket);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != StreamSocketFD.invalid; }

	@property void tcpNoDelay(bool enabled) { eventDriver.sockets.setTCPNoDelay(m_socket, enabled); m_context.tcpNoDelay = enabled; }
	@property bool tcpNoDelay() const { return m_context.tcpNoDelay; }
	@property void keepAlive(bool enabled) { eventDriver.sockets.setKeepAlive(m_socket, enabled); m_context.keepAlive = enabled; }
	@property bool keepAlive() const { return m_context.keepAlive; }
	@property void readTimeout(Duration duration) { m_context.readTimeout = duration; }
	@property Duration readTimeout() const { return m_context.readTimeout; }
	@property string peerAddress() const { return m_context.remoteAddress.toString(); }
	@property NetworkAddress localAddress() const { return localAddress; }
	@property NetworkAddress remoteAddress() const { return remoteAddress; }
	@property bool connected()
	const {
		if (m_socket == StreamSocketFD.invalid) return false;
		auto s = eventDriver.sockets.getConnectionState(m_socket);
		return s >= ConnectionState.connected && s < ConnectionState.activeClose;
	}
	@property bool empty() { return leastSize == 0; }
	@property ulong leastSize() { waitForData(); return m_context.readBuffer.length; }
	@property bool dataAvailableForRead() { return waitForData(0.seconds); }
	
	void close()
	nothrow {
		//logInfo("close %s", cast(int)m_fd);
		if (m_socket != StreamSocketFD.invalid) {
			eventDriver.sockets.shutdown(m_socket, true, true);
			eventDriver.sockets.releaseRef(m_socket);
			m_socket = StreamSocketFD.invalid;
			m_context = null;
		}
	}
	
	bool waitForData(Duration timeout = Duration.max)
	{
mixin(tracer);
		if (m_context.readBuffer.length > 0) return true;
		auto mode = timeout <= 0.seconds ? IOMode.immediate : IOMode.once;

		Waitable!(
			cb => eventDriver.sockets.read(m_socket, m_context.readBuffer.peekDst(), mode, cb),
			cb => eventDriver.sockets.cancelRead(m_socket),
			IOCallback
		) waiter;

		asyncAwaitAny!true(timeout, waiter);

		if (waiter.cancelled) return false;

		logTrace("Socket %s, read %s bytes: %s", waiter.results[0], waiter.results[2], waiter.results[1]);

		assert(m_context.readBuffer.length == 0);
		m_context.readBuffer.putN(waiter.results[2]);
		switch (waiter.results[1]) {
			default:
				logInfo("read status %s", waiter.results[1]);
				throw new Exception("Error reading data from socket.");
			case IOStatus.ok: break;
			case IOStatus.wouldBlock: assert(mode == IOMode.immediate); break;
			case IOStatus.disconnected: break;
		}

		return m_context.readBuffer.length > 0;
	}

	const(ubyte)[] peek() { return m_context.readBuffer.peek(); }

	void skip(ulong count)
	{
		import std.algorithm.comparison : min;

		m_context.readTimeout.loopWithTimeout!((remaining) {
			waitForData(remaining);
			auto n = min(count, m_context.readBuffer.length);
			m_context.readBuffer.popFrontN(n);
			count -= n;
			return count == 0;
		});
	}

	void read(ubyte[] dst)
	{
mixin(tracer);
		import std.algorithm.comparison : min;
		if (!dst.length) return;
		m_context.readTimeout.loopWithTimeout!((remaining) {
			enforce(waitForData(), "Reached end of stream while reading data.");
			assert(m_context.readBuffer.length > 0);
			auto l = min(dst.length, m_context.readBuffer.length);
			m_context.readBuffer.read(dst[0 .. l]);
			dst = dst[l .. $];
			return dst.length == 0;
		});
	}

	void write(in ubyte[] bytes)
	{
mixin(tracer);
		if (bytes.length == 0) return;

		auto res = asyncAwait!(IOCallback,
			cb => eventDriver.sockets.write(m_socket, bytes, IOMode.all, cb),
			cb => eventDriver.sockets.cancelWrite(m_socket));
		
		switch (res[1]) {
			default:
				throw new Exception("Error writing data to socket.");
			case IOStatus.ok: break;
			case IOStatus.disconnected: break;

		}
	}

	void write(in char[] bytes) { write(cast(const(ubyte)[])bytes); }
	void write(InputStream stream) { write(stream, 0); }

	void flush() {
mixin(tracer);
	}
	void finalize() {}
	void write(InputStream)(InputStream stream, ulong nbytes = 0) if (isInputStream!InputStream) { writeDefault(stream, nbytes); }

	private void writeDefault(InputStream)(InputStream stream, ulong nbytes = 0)
		if (isInputStream!InputStream)
	{
		import std.algorithm.comparison : min;

		static struct Buffer { ubyte[64*1024 - 4*size_t.sizeof] bytes = void; }
		scope bufferobj = new Buffer; // FIXME: use heap allocation
		auto buffer = bufferobj.bytes[];

		//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
		if( nbytes == 0 ){
			while( !stream.empty ){
				size_t chunk = min(stream.leastSize, buffer.length);
				assert(chunk > 0, "leastSize returned zero for non-empty stream.");
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
			}
		} else {
			while( nbytes > 0 ){
				size_t chunk = min(nbytes, buffer.length);
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
				nbytes -= chunk;
			}
		}
	}
}

mixin validateConnectionStream!TCPConnection;

private void loopWithTimeout(alias LoopBody, ExceptionType = Exception)(Duration timeout)
{
	import core.time : seconds;
	import std.datetime : Clock, SysTime, UTC;

	SysTime now;
	if (timeout != Duration.max)
		now = Clock.currTime(UTC());

	do {
		if (LoopBody(timeout))
			return;
		
		if (timeout != Duration.max) {
			auto prev = now;
			now = Clock.currTime(UTC());
			if (now > prev) timeout -= now - prev;
		}
	} while (timeout > 0.seconds);

	throw new ExceptionType("Operation timed out.");
}


/**
	Represents a listening TCP socket.
*/
struct TCPListener {
	private {
		StreamListenSocketFD m_socket;
		NetworkAddress m_bindAddress;
	}

	this(StreamListenSocketFD socket)
	{
		m_socket = socket;
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != StreamListenSocketFD.invalid; }

	/// The local address at which TCP connections are accepted.
	@property NetworkAddress bindAddress()
	{
		return m_bindAddress;
	}

	/// Stops listening and closes the socket.
	void stopListening()
	{
		assert(false);
	}
}


/**
	Represents a bound and possibly 'connected' UDP socket.
*/
struct UDPConnection {
	static struct Context {
		bool canBroadcast;
		NetworkAddress remoteAddress;
		NetworkAddress localAddress;
	}

	private {
		DatagramSocketFD m_socket;
		Context* m_context;
	}

	private this(ref NetworkAddress bind_address) 
	{
		m_socket = eventDriver.sockets.createDatagramSocket(bind_address.toUnknownAddress(), null);
		m_context = () @trusted { return &eventDriver.core.userData!Context(m_socket); } ();
		m_context.localAddress = bind_address;
	}


	this(this)
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.releaseRef(m_socket);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != DatagramSocketFD.invalid; }

	/** Returns the address to which the UDP socket is bound.
	*/
	@property string bindAddress() const { return localAddress.toString(); }

	/** Determines if the socket is allowed to send to broadcast addresses.
	*/
	@property bool canBroadcast() const { return m_context.canBroadcast; }
	/// ditto
	@property void canBroadcast(bool val) { enforce(eventDriver.sockets.setBroadcast(m_socket, val), "Failed to set UDP broadcast flag."); m_context.canBroadcast = val; }

	/// The local/bind address of the underlying socket.
	@property NetworkAddress localAddress() const { return m_context.localAddress; }

	/** Stops listening for datagrams and frees all resources.
	*/
	void close() { eventDriver.sockets.releaseRef(m_socket); m_socket = DatagramSocketFD.init; }

	/** Locks the UDP connection to a certain peer.

		Once connected, the UDPConnection can only communicate with the specified peer.
		Otherwise communication with any reachable peer is possible.
	*/
	void connect(string host, ushort port) { connect(resolveHost(host, port)); }
	/// ditto
	void connect(NetworkAddress address) { m_context.remoteAddress = address; }

	/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	*/
	void send(in ubyte[] data, in NetworkAddress* peer_address = null)
	{
		auto addr = () @trusted { return peer_address ? peer_address : &m_context.remoteAddress; } ();
		scope addrc = new RefAddress(() @trusted { return (cast(NetworkAddress*)addr).sockAddr; } (), addr.sockAddrLen);

		auto ret = asyncAwait!(DatagramIOCallback,
			cb => eventDriver.sockets.send(m_socket, data, IOMode.once, addrc, cb),
			cb => eventDriver.sockets.cancelSend(m_socket)
		);
		enforce(ret[1] == IOStatus.ok, "Failed to send packet.");
		enforce(ret[2] == data.length, "Packet was only sent partially.");
	}

	/** Receives a single packet.

		If a buffer is given, it must be large enough to hold the full packet.

		The timeout overload will throw an Exception if no data arrives before the
		specified duration has elapsed.
	*/
	ubyte[] recv(ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		return recv(Duration.max, buf, peer_address);
	}
	/// ditto
	ubyte[] recv(Duration timeout, ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		import std.socket : Address;
		if (buf.length == 0) buf = new ubyte[65536];
		auto res = asyncAwait!(DatagramIOCallback,
			cb => eventDriver.sockets.receive(m_socket, buf, IOMode.once, cb),
			cb => eventDriver.sockets.cancelReceive(m_socket)
		)(timeout);
		enforce(res.completed, "Receive timeout.");
		enforce(res.results[1] == IOStatus.ok, "Failed to receive packet.");
		if (peer_address) *peer_address = NetworkAddress(res.results[3]);
		return buf[0 .. res.results[2]];
	}
}


/**
	Flags to control the behavior of listenTCP.
*/
enum TCPListenOptions {
	/// Don't enable any particular option
	defaults = 0,
	/// Causes incoming connections to be distributed across the thread pool
	distribute = 1<<0,
	/// Disables automatic closing of the connection when the connection callback exits
	disableAutoClose = 1<<1,
	/** Enable port reuse on linux kernel version >=3.9, do nothing on other OS
	    Does not affect libasync driver because it is always enabled by libasync.
	*/
	reusePort = 1<<2,
}

private pure nothrow {
	import std.bitmanip;

	ushort ntoh(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}

	ushort hton(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}
}

private enum tracer = "";

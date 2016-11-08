module vibe.internal.interfaceproxy;

import vibe.internal.traits;
import std.meta : staticMap;
import std.traits : BaseTypeTuple;


O asInterface(I, O)(O obj) if (is(I == interface) && is(O : I)) { return obj; }
InterfaceProxyClass!(I, O) asInterface(I, O)(O obj) if (is(I == interface) && !is(O : I)) { return new InterfaceProxyClass!(I, O)(obj); }

private class InterfaceProxyClass(I, O) : I
{
	import std.meta : AliasSeq;
	import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;

	private {
		O m_obj;
	}

	this(O obj) { m_obj = obj; }

	mixin methodDefs!0;

	private mixin template methodDefs(size_t idx) {
		alias Members = AliasSeq!(__traits(allMembers, I));
		static if (idx < Members.length) {
			mixin overloadDefs!(Members[idx]);
			mixin methodDefs!(idx+1);
		}
	}

	mixin template overloadDefs(string mem) {
		alias Overloads = MemberFunctionsTuple!(I, mem);

		private static string impl()
		{
			import std.format : format;
			string ret;
			foreach (idx, F; Overloads) {
				alias R = ReturnType!F;
				enum attribs = functionAttributeString!F(false);
				static if (__traits(isVirtualMethod, F)) {
					static if (is(R == void))
						ret ~= q{override %s void %s(ParameterTypeTuple!(Overloads[%s]) params) { m_obj.%s(params); }}
							.format(attribs, mem, idx, mem);
					else
						ret ~= q{override %s ReturnType!(Overloads[%s]) %s(ParameterTypeTuple!(Overloads[%s]) params) { return m_obj.%s(params); }}
							.format(attribs, idx, mem, idx, mem);
				}
			}
			return ret;
		}

		mixin(impl());
	}
}



struct InterfaceProxy(I) if (is(I == interface)) {
	import std.meta : AliasSeq;
	import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;
	import vibe.internal.traits : checkInterfaceConformance;

	private {
		void[4*(void*).sizeof] m_value;
		Proxy m_intf;
	}

	this(IP : InterfaceProxy!J, J)(IP proxy) @safe
	{
		() @trusted { m_value[] = proxy.m_value[]; } ();
		m_intf = proxy.m_intf;
		m_intf._postblit(m_value);
	}

	this(O)(O object) @trusted
	{
		static assert(O.sizeof <= m_value.length, "Object is too big to be stored in an InterfaceProxy.");
		import std.conv : emplace;
		m_intf = ProxyImpl!O.get();
		emplace!O(m_value[0 .. O.sizeof]);
		(cast(O[])m_value[0 .. O.sizeof])[0] = object;
	}

	~this() @safe
	{
		clear();
	}

	this(this) @safe
	{
		if (m_intf) m_intf._postblit(m_value);
	}

	void clear() @safe nothrow
	{
		if (m_intf) {
			m_intf._destroy(m_value);
			m_intf = null;
		}
	}

	T extract(T)()
	@trusted nothrow {
		if (!m_intf || m_intf._typeInfo() !is typeid(T))
			assert(false, "Extraction of wrong type from InterfaceProxy.");
		return (cast(T[])m_value[0 .. T.sizeof])[0];
	}

	void opAssign(IP : InterfaceProxy!J, J)(IP proxy) @safe
	{
		static assert(is(J : I), "Can only assign InterfaceProxy instances of derived interfaces.");

		clear();
		if (proxy.m_intf) {
			() @trusted { m_value[] = proxy.m_value[]; } ();
			m_intf = proxy.m_intf;
			m_intf._postblit(m_value);
		}
	}

	void opAssign(O)(O object) @trusted
		if (checkInterfaceConformance!(O, I) is null)
	{
		static assert(O.sizeof <= m_value.length, "Object is too big to be stored in an InterfaceProxy.");
		import std.conv : emplace;
		clear();
		m_intf = ProxyImpl!O.get();
		emplace!O(m_value[0 .. O.sizeof]);
		(cast(O[])m_value[0 .. O.sizeof])[0] = object;
	}

	bool opCast(T)() const @safe nothrow if (is(T == bool)) { return m_intf !is null; }

	mixin allMethods!0;

	private mixin template allMethods(size_t idx) {
		alias Members = AliasSeq!(__traits(allMembers, I));
		static if (idx < Members.length) {
			static if (__traits(compiles, __traits(getMember, I, Members[idx])))
				mixin overloadMethods!(Members[idx]);
			mixin allMethods!(idx+1);
		}
	}

	private mixin template overloadMethods(string member) {
		alias Overloads = AliasSeq!(__traits(getOverloads, I, member));

		private static string impl()
		{
			import std.format : format;
			string ret;
			foreach (idx, F; Overloads) {
				enum attribs = functionAttributeString!F(false);
				enum is_prop = functionAttributes!F & FunctionAttribute.property;
				ret ~= q{%s ReturnType!(Overloads[%s]) %s(ParameterTypeTuple!(Overloads[%s]) params) { return m_intf.%s(m_value, params); }}
					.format(attribs, idx, member, idx, member);
			}
			return ret;
		}
		
		mixin(impl());
	}

	private interface Proxy : staticMap!(ProxyOf, BaseTypeTuple!I) {
		import std.meta : AliasSeq;
		import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;

		void _destroy(void[] stor) @safe nothrow;
		void _postblit(void[] stor) @safe nothrow;
		TypeInfo _typeInfo() @safe nothrow;

		mixin methodDecls!0;

		private mixin template methodDecls(size_t idx) {
			alias Members = AliasSeq!(__traits(derivedMembers, I));
			static if (idx < Members.length) {
				static if (__traits(compiles, __traits(getMember, I, Members[idx])))
					mixin overloadDecls!(Members[idx]);
				mixin methodDecls!(idx+1);
			}
		}

		private mixin template overloadDecls(string mem) {
			alias Overloads = AliasSeq!(__traits(getOverloads, I, mem));

			private static string impl()
			{
				import std.format : format;
				string ret;
				foreach (idx, F; Overloads) {
					enum attribs = functionAttributeString!F(false);
					enum vtype = functionAttributeThisType!F("void[]");
					ret ~= q{ReturnType!(Overloads[%s]) %s(%s obj, ParameterTypeTuple!(Overloads[%s]) params) %s;}
						.format(idx, mem, vtype, idx, attribs);
				}
				return ret;
			}

			mixin(impl());
		}
	}

	static final class ProxyImpl(O) : Proxy {
		static auto get()
		{
			static ProxyImpl impl;
			if (!impl) impl = new ProxyImpl;
			return impl;
		}

		void _destroy(void[] stor)
		@trusted nothrow {
			try destroy(_extract(stor));
			catch (Exception e) assert(false, "Destructor has thrown: "~e.msg);
		}

		void _postblit(void[] stor)
		@trusted nothrow {
			try typeid(O).postblit(stor.ptr);
			catch (Exception e) assert(false, "Postblit contructor has thrown: "~e.msg);
		}

		TypeInfo _typeInfo()
		@safe nothrow {
			return typeid(O);
		}

		static ref inout(O) _extract(inout(void)[] stor)
		@trusted nothrow pure @nogc {
			return (cast(inout(O)[])stor[0 .. O.sizeof])[0];
		}

		mixin methodDefs!0;

		private mixin template methodDefs(size_t idx) {
			alias Members = AliasSeq!(__traits(allMembers, I));
			static if (idx < Members.length) {
				static if (__traits(compiles, __traits(getMember, I, Members[idx])))
					mixin overloadDefs!(Members[idx]);
				mixin methodDefs!(idx+1);
			}
		}

		private mixin template overloadDefs(string mem) {
			alias Overloads = AliasSeq!(__traits(getOverloads, I, mem));

			private static string impl()
			{
				import std.format : format;
				string ret;
				foreach (idx, F; Overloads) {
					alias R = ReturnType!F;
					alias P = ParameterTypeTuple!F;
					enum attribs = functionAttributeString!F(false);
					enum vtype = functionAttributeThisType!F("void[]");

					static if (is(R == void))
						ret ~= q{override void %s(%s obj, ParameterTypeTuple!(Overloads[%s]) params) %s { _extract(obj).%s(params); }}
							.format(mem, vtype, idx, attribs, mem);
					else
						ret ~= q{override ReturnType!(Overloads[%s]) %s(%s obj, ParameterTypeTuple!(Overloads[%s]) params) %s { return _extract(obj).%s(params); }}
							.format(idx, mem, vtype, idx, attribs, mem);
				}
				return ret;
			}

			mixin(impl());
		}
	}
}

private alias ProxyOf(I) = InterfaceProxy!I.Proxy;

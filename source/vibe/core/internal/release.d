module vibe.core.internal.release;

import eventcore.core;

/// Release a handle in a thread-safe way
void releaseHandle(string subsys, H)(H handle, shared(NativeEventDriver) drv)
{
	if (drv is (() @trusted => cast(shared)eventDriver)()) {
		__traits(getMember, eventDriver, subsys).releaseRef(handle);
	} else {
		// if the owner driver has already been disposed, there is nothing we
		// can do anymore
		if (!drv.core) {
			import vibe.core.log : logWarn;
			logWarn("Leaking %s handle %s, because owner thread/driver has already terminated",
				H.name, handle.value);
			return;
		}

		// in case the destructor was called from a foreign thread,
		// perform the release in the owner thread
		drv.core.runInOwnerThread((h) {
			__traits(getMember, eventDriver, subsys).releaseRef(cast(H)h);
		}, cast(size_t)handle);
	}
}

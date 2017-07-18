/** Implements a thread-safe, typed producer-consumer queue.

	Copyright: © 2017 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.channel;

// multiple producers allowed, multiple consumers allowed - Q: should this be restricted to allow higher performance? maybe configurable?
// currently always buffered - TODO: implement blocking non-buffered mode
// TODO: implement a multi-channel wait, e.g.
// TaggedAlgebraic!(...) consumeAny(ch1, ch2, ch3); - requires a waitOnMultipleConditions function
// TODO: implement close()
// TODO: fully support non-copyable types using swap/move where appropriate
// TODO: add unit tests
// Q: Should this be exposed as a class, or as an RC struct?

private final class Channel(T, size_t buffer_size = 100) {
	import vibe.core.concurrency : isWeaklyIsolated;
	static assert(isWeaklyIsolated!T, "Channel data type "~T.stringof~" is not safe to pass between threads.");

	Mutex m_mutex;
	TaskCondition m_condition;
	FixedRingBuffer!(T, buffer_size) m_items;

	this()
	shared {
		m_mutex = cast(shared)new Mutex;
		m_condition = cast(shared)new TaskCondition(cast(Mutex)m_mutex);
	}

	bool empty()
	shared {
		synchronized (m_mutex)
			return (cast(Channel)this).m_items.empty;
	}

	T consumeOne()
	shared {
		auto thisus = cast(Channel)this;
		T ret;
		bool was_full = false;
		synchronized (m_mutex) {
			while (thisus.m_items.empty)
				thisus.m_condition.wait();
			was_full = thisus.m_items.full;
			swap(thisus.m_items.front, ret);
		}
		if (was_full) thisus.m_condition.notifyAll();
		return ret.move;
	}

	void consumeAll(ref FixedRingBuffer!(T, buffer_size) dst)
	shared {
		auto thisus = cast(Channel)this;
		bool was_full = false;
		synchronized (m_mutex) {
			while (thisus.m_items.empty)
				thisus.m_condition.wait();
			was_full = thisus.m_items.full;
			swap(thisus.m_items, dst);
		}
		if (was_full) thisus.m_condition.notifyAll();
	}

	void put(T item)
	shared {
		auto thisus = cast(Channel)this;
		bool need_notify = false;
		synchronized (m_mutex) {
			while (thisus.m_items.full)
				thisus.m_condition.wait();
			need_notify = thisus.m_items.empty;
			thisus.m_items.put(item.move);
		}
		if (need_notify) thisus.m_condition.notifyAll();
	}
}

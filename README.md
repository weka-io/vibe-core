vibe.d core module
==================

This is the designated successor of the `vibe-d:core` sub package of [vibe.d 0.7.x](https://github.com/rejectedsoftware/vibe.d.git). The API is mostly compatible from a library user point of view, but the whole library has received some heavy lifting under the surface, close to a rewrite. Most classes have been replaced by reference counting structs and `@safe nothrow` attributes are now used throughout the library, whenever possible. Adding `@nogc` on the other hand could only be done in a very limited context due to its viral nature and the lack of an `@trusted` equivalent.

Another major design change is that instead of the previous driver model, there is now a separate, lower-level event loop abstraction ([eventcore](https://github.com/vibe-d/eventcore.git)) which follows a callback based Proactor pattern. The logic to schedule fibers based on events has been pulled out of this abstraction and is now maintained as a single function, leading to a huge improvment in terms of robustness (most issues in the previous implementation have probably never surfaced in practice, but there turned out to be lots of them).

Finally, the stream design has received two big changes. Streams can now either be implemented as classes, as usual, or they can be implemented as structs in a duck typing/DbC fashion. This, coupled with templated wrapper stream types, allows to eliminate the overhead of virtual function calls, enables reference counting instead of GC allocations, and allows the compiler to inline across stream boundaries. The second change to streams is the added support for an [`IOMode`](https://github.com/vibe-d/eventcore/blob/c242fdae16470ae4dc4e7e6578d582c1d3ba57ec/source/eventcore/driver.d#L533) parameter that enables I/O patterns as they are possible when using OS sockets directly. The `leastSize` and `dataAvailableForRead` properties will in turn be deprecated.

The implementation is mostly finished, except for final production testing.

[![DUB Package](https://img.shields.io/dub/v/vibe-core.svg)](https://code.dlang.org/packages/vibe-core)
[![Posix Build Status](https://travis-ci.org/vibe-d/vibe-core.svg?branch=master)](https://travis-ci.org/vibe-d/vibe-core)
[![Windows Build status](https://ci.appveyor.com/api/projects/status/eexephyroa7ag3xr/branch/master?svg=true)](https://ci.appveyor.com/project/s-ludwig/vibe-core/branch/master)


Supported compilers
-------------------

The following compilers are tested and supported:

- DMD 2.073.0
- DMD 2.072.2
- DMD 2.071.2
- DMD 2.070.2
- LDC 1.1.0
- LDC 1.0.0

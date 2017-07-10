1.0.0 - 2016-07-10
==================

This is the initial release of the `vibe-core` package. The source code was derived from the original `:core` sub package of vibe.d and received a complete work over, mostly under the surface, but also in parts of the API. The changes have been made in a way that is usually backwards compatible from the point of view of an application developer. At the same time, vibe.d 0.8.0 contains a number of forward compatibility declarations, so that switching back and forth between the still existing `vibe-d:core` and `vibe-core` is possible without changing the application code.

To use this package, it is currently necessary to put an explicit dependency with a sub configuration directive in the DUB package recipe:
```
// for dub.sdl:
dependency "vibe-d:core" version="~>0.8.0"
subConfiguration "vibe-d:core" "vibe-core"

// for dub.json:
"dependencies": {
	"vibe-d:core": "~>0.8.0"
},
"subConfigurations": {
	"vibe-d:core": "vibe-core"
}
```
During the development of the 0.8.x branch of vibe.d, the default will eventually be changed, so that `vibe-core` is the default instead.


Major changes
-------------

- The high-level event and task scheduling abstraction has been replaced by the low level Proactor abstraction [eventcore][eventcore], which also means that there is no dependency to libevent anymore.
- GC allocated classes have been replaced by reference counted `struct`s, with their storage backed by a compact array together with event loop specific data.
- `@safe` and `nothrow` have been added throughout the code base, `@nogc` in some parts where no user callbacks are involved.
- The task/fiber scheduling logic has been unified, leading to a major improvement in robustness in case of exceptions or other kinds of interruptions.
- The single `Path` type has been replaced by `PosixPath`, `WindowsPath`, `InetPath` and `NativePath`, where the latter is an alias to either `PosixPath` or `WindowsPath`. This greatly improves the robustness of path handling code, since it is no longer possible to blindly mix different path types (especially file system paths and URI paths).
- Streams (`InputStream`, `OutputStream` etc.) can now also be implemented as `struct`s instead of classes. All API functions accept stream types as generic types now, meaning that allocations and virtual function calls can be eliminated in many cases and function inlining can often work across stream boundaries.
- There is a new `IOMode` parameter for read and write operations that enables a direct translation of operating system provided modes ("write as much as possible in one go" or "write only if possible without blocking").

[eventcore]: https://github.com/vibe-d/eventcore

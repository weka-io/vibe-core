1.2.0 - 2017-09-
==================

- Compiles on DMD 2.071.2 up to 2.076.0
- Marked a number of classes as `final` that were accidentally left as overridable
- Un-deprecated `GenericPath.startsWith` due to the different semantics compared to the replacement suggestion
- Fixed a deadlock caused by an invalid lock count in `LocalTaskSemaphore` (by Boris-Barboris) - [pull #31][issue31]
- Fixed `FileDescriptorEvent` to adhere to the given event mask
- Fixed `FileDescriptorEvent.wait` in conjunction with a finite timeout
- Fixed the return value of `FileDescriptorEvent.wait`

[issue31]: https://github.com/vibe-d/vibe-core/issues/31


1.1.1 - 2017-07-20
==================

- Fixed/implemented `TCPListener.stopListening`
- Fixed a crash when using `NullOutputStream` or other class based streams
- Fixed a "dwarfeh(224) fatal error" when the process gets terminated due to an `Error` - [pull #24][issue24]
- Fixed assertion error when `NetworkAddress.to(Address)String` is called with no address set
- Fixed multiple crash and hanging issues with `(Local)ManualEvent` - [pull #26][issue26]

[issue24]: https://github.com/vibe-d/vibe-core/issues/24
[issue26]: https://github.com/vibe-d/vibe-core/issues/26


1.1.0 - 2017-07-16
==================

- Added a new debug hook `setTaskCreationCallback`
- Fixed a compilation error for `VibeIdleCollect`
- Fixed a possible double-free in `ManualEvent` that resulted in an endless loop - [pull #23][issue23]

[issue23]: https://github.com/vibe-d/vibe-core/issues/23


1.0.0 - 2017-07-10
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

vibe.d core module
==================

This is the designated successor of the `vibe-d:core` sub package of [vibe.d 0.7.x](https://github.com/rejectedsoftware/vibe.d.git). The API is mostly compatible from a library user point of view, but the whole library has received some heavy lifting under the surface, close to a rewrite. Most classes have been replaced by reference counting structs and `@safe nothrow` attributes are now used throughout the library, whenever possible. Adding `@nogc` still has to be decided, because of its viral nature.

Another major design change is that instead of the previous driver model, there is now a separate, lower-level event loop abstraction ([eventcore](https://github.com/vibe-d/eventcore.git)) which follows a callback based Proactor pattern. The logic to schedule fibers based on events has been pulled out of this abstraction and is now maintained as a single function, leaving to a huge improvment in terms of robustness (most issues in the previous implementation have probably never surfaced in practice, but there turned out to be lots of hidden bugs).

The implementation is mostly finished, except for final production testing and a final review of the stream API. Also, eventcore is still missing WinAPI and kqueue implementations.

[![Build Status](https://travis-ci.org/vibe-d/vibe-core.svg?branch=master)](https://travis-ci.org/vibe-d/vibe-core)


Progress
--------

Feature             | State
--------------------|---------
Task scheduling     | done
Concurrency         | done
Streams             | done (may be subject to smaller changes)
DNS lookup          | done
TCP connections     | done
UDP connections     | done
File I/O            | done
Directory watchers  | done
ManualEvent         | done
Path/URL types      | done

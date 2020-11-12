vibe_core_src = files(
	'appmain.d',
	'internal/array.d',
	'internal/list.d',
	'internal/typetuple.d',
	'internal/freelistref.d',
	'internal/allocator.d',
	'internal/traits.d',
	'internal/string.d',
	'internal/hashmap.d',
	'internal/interfaceproxy.d',
	'internal/async.d',
	'core/log.d',
	'core/stream.d',
	'core/file.d',
	'core/channel.d',
	'core/concurrency.d',
	'core/args.d',
	'core/core.d',
	'core/task.d',
	'core/internal/release.d',
	'core/net.d',
	'core/taskpool.d',
	'core/connectionpool.d',
	'core/path.d',
	'core/sync.d',
	'core/process.d',
)

vibe_core_lib = library('vibe-core',
	vibe_core_src,
	version: project_version,
	install: true,
	pic: true,
	include_directories: include_directories('../'),
	dependencies: [eventcore_dep, allocator_dep],
)

pkgc = import('pkgconfig')

pkgc.generate(
	vibe_core_lib,
	subdirs: 'd/vibe-core',
	libraries_private: eventcore_dep,
)

install_subdir('.',
	exclude_files: ['meson.build'],
	install_dir: 'include/d/vibe-core/vibe',
)

#
# Tests
#
vibe_test_core_exe = executable('vibe-test_core',
	vibe_core_src,
	include_directories: include_directories('../'),
	dependencies: [eventcore_dep, allocator_dep],
	d_unittest: true,
	link_args: '--main'
)
test('vibe-test_core', vibe_test_core_exe)

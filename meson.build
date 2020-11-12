project('vibe_core', 'd',
    meson_version: '>=0.56',
    version: '1.11.0',
    default_options: ['buildtype=release']
)

project_soversion      = '0'
project_version_suffix = ''
project_version        = meson.project_version()
project_version_full   = project_version + project_version_suffix

eventcore_dep = dependency('eventcore', version: ['>=0.9.2', '<0.10.0'], static: true)
allocator_dep = dependency('stdx-allocator', version: ['>=2.77.0', '<2.78.0'], static: true)

source_root = meson.current_source_dir()
build_root = meson.current_build_dir()
subdir('source/vibe')

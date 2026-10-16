project('singularity-machines', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-machines"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4', version: '>= 4.12')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
gio_unix_dep = dependency('gio-unix-2.0')
m_dep = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

prefix = get_option('prefix')
config_c_args = [
  '-DMACHINES_SYSCONFDIR="@0@"'.format(prefix / get_option('sysconfdir')),
  '-DMACHINES_DATADIR="@0@"'.format(prefix / get_option('datadir')),
  '-DMACHINES_DEFAULT_BACKEND="@0@"'.format(get_option('vm-backend')),
  '-DMACHINES_DEFAULT_QEMU="@0@"'.format(get_option('qemu')),
  '-DMACHINES_FIRMWARE_DIRS="@0@"'.format(get_option('firmware-dirs')),
  '-DMACHINES_OSINFO_DIRS="@0@"'.format(get_option('osinfo-dirs')),
]
vala_args = ['--pkg=posix']
if get_option('libvirt')
  vala_args += ['-D', 'HAVE_LIBVIRT']
endif

core_sources = files(
  'src/host.vala',
  'src/osinfo.vala',
  'src/detect.vala',
  'src/machine.vala',
  'src/qemu_command.vala',
)

sources = core_sources + files(
  'src/qmp.vala',
  'src/backend.vala',
  'src/qemu_backend.vala',
  'src/libvirt_backend.vala',
  'src/manager.vala',
  'src/card.vala',
  'src/create.vala',
  'src/details.vala',
  'src/window.vala',
  'src/main.vala',
)

executable('singularity-machines',
  sources,
  vala_args: vala_args,
  c_args: config_c_args,
  dependencies: [gtk_dep, gee_dep, json_dep, gio_unix_dep, m_dep, libsingularity_dep],
  install: true
)

install_data('data/dev.sinty.machines.desktop',
  install_dir: get_option('datadir') / 'applications'
)

service_conf = configuration_data()
service_conf.set('bindir', prefix / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.machines.service.in',
  output: 'dev.sinty.machines.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.machines.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.machines.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.machines.svg', 'data/icons/dev.sinty.machines-snapshot.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

test_c_args = config_c_args
test_deps = [dependency('gio-2.0'), gee_dep, json_dep]
fixtures = meson.current_source_dir() / 'tests' / 'fixtures'

config_test = executable('machines-config-test',
  core_sources + files('tests/config_test.vala'),
  vala_args: ['--pkg=posix'], c_args: test_c_args, dependencies: test_deps)
test('config', config_test, env: ['FIXTURES=' + fixtures])

osinfo_test = executable('machines-osinfo-test',
  core_sources + files('tests/osinfo_test.vala'),
  vala_args: ['--pkg=posix'], c_args: test_c_args, dependencies: test_deps)
test('osinfo', osinfo_test, env: ['FIXTURES=' + fixtures])

command_test = executable('machines-command-test',
  core_sources + files('tests/command_test.vala', 'src/libvirt_backend.vala', 'src/backend.vala', 'src/qemu_backend.vala', 'src/qmp.vala'),
  vala_args: ['--pkg=posix'], c_args: test_c_args, dependencies: test_deps + [gio_unix_dep])
test('command', command_test, env: ['FIXTURES=' + fixtures])

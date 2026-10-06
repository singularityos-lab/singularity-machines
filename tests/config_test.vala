using Singularity.Apps.Machines;

namespace Scratch {
    public GenericArray<string> dirs;

    public string make () {
        if (dirs == null) dirs = new GenericArray<string> ();
        try {
            string d = DirUtils.make_tmp ("machines-test-XXXXXX");
            dirs.add (d);
            return d;
        } catch (Error e) {
            assert_not_reached ();
        }
    }

    private void remove_tree (string path) {
        if (FileUtils.test (path, FileTest.IS_DIR) && !FileUtils.test (path, FileTest.IS_SYMLINK)) {
            try {
                var d = Dir.open (path);
                string? name;
                while ((name = d.read_name ()) != null) remove_tree (Path.build_filename (path, name));
            } catch (Error e) {
            }
            DirUtils.remove (path);
        } else {
            FileUtils.unlink (path);
        }
    }

    public void clean () {
        if (dirs == null) return;
        foreach (string d in dirs.data) remove_tree (d);
    }
}

string tmpdir () {
    return Scratch.make ();
}

void write_file (string path, string text) {
    try {
        FileUtils.set_contents (path, text);
    } catch (Error e) {
        assert_not_reached ();
    }
}

string descriptor (string code, string vars, string arch, string features) {
    return """{
  "interface-types": ["uefi"],
  "mapping": {
    "device": "flash",
    "executable": {"filename": "%s", "format": "raw"},
    "nvram-template": {"filename": "%s", "format": "raw"}
  },
  "targets": [{"architecture": "%s", "machines": ["pc-q35-*"]}],
  "features": [%s]
}""".printf (code, vars, arch, features);
}

string fixtures_dir () {
    return Environment.get_variable ("FIXTURES") ?? "tests/fixtures";
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/machine/json-roundtrip", () => {
        var m = new Machine ();
        m.id = "a1b2c3d4";
        m.name = "Alpine, test";
        m.os_id = "http://alpinelinux.org/alpinelinux/3.21";
        m.os_name = "Alpine Linux 3.21";
        m.memory_mib = 1536;
        m.cpus = 3;
        m.disk_gib = 12;
        m.uefi = true;
        m.firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd";
        m.install_media = "/images/alpine.iso";
        m.shared_folder = "/home/user/Public";
        m.resize_guest = false;
        m.created = 1700000000;
        var s = new SnapshotInfo ();
        s.tag = "snap-1";
        s.name = "Before update";
        s.created = 1700000100;
        s.with_state = true;
        m.snapshots.add (s);
        var back = Machine.parse (m.serialize ());
        assert (back != null);
        assert (back.id == "a1b2c3d4");
        assert (back.name == "Alpine, test");
        assert (back.os_id == m.os_id);
        assert (back.memory_mib == 1536);
        assert (back.cpus == 3);
        assert (back.disk_gib == 12);
        assert (back.uefi);
        assert (back.firmware_code == "/usr/share/OVMF/OVMF_CODE_4M.fd");
        assert (back.firmware_format == "raw");
        assert (back.install_media == "/images/alpine.iso");
        assert (back.shared_folder == "/home/user/Public");
        assert (!back.resize_guest);
        assert (back.created == 1700000000);
        assert (back.snapshots.size == 1);
        assert (back.snapshots[0].tag == "snap-1");
        assert (back.snapshots[0].name == "Before update");
        assert (back.snapshots[0].with_state);
        assert (back.find_snapshot ("snap-1") != null);
        assert (back.find_snapshot ("nope") == null);
    });

    Test.add_func ("/machine/defaults-and-limits", () => {
        var m = Machine.parse ("{\"id\": \"x1\", \"memory-mib\": 5, \"cpus\": 0, \"snapshots\": [{\"name\": \"no tag\"}]}");
        assert (m != null);
        assert (m.memory_mib == 128);
        assert (m.cpus == 1);
        assert (m.disk_gib == 20);
        assert (m.backend == "qemu");
        assert (m.resize_guest);
        assert (m.snapshots.size == 0);
        assert (Machine.parse ("{}") == null);
        assert (Machine.parse ("not json") == null);
        assert (Machine.parse ("[1, 2]") == null);
        assert (Machine.new_id ().length == 8);
    });

    Test.add_func ("/machine/title", () => {
        var m = new Machine ();
        m.os_name = "Debian 12";
        assert (m.title () == "Debian 12");
        m.name = "Server";
        assert (m.title () == "Server");
    });

    Test.add_func ("/store/save-load-remove", () => {
        string root = Path.build_filename (tmpdir (), "machines");
        var store = new MachineStore (root);
        var m = new Machine ();
        m.name = "One";
        m.last_used = 10;
        try {
            store.allocate_dir (m);
            store.save (m);
        } catch (Error e) {
            assert_not_reached ();
        }
        assert (m.id.length == 8);
        assert (FileUtils.test (m.config_path (), FileTest.IS_REGULAR));
        var two = new Machine ();
        two.name = "Two";
        two.last_used = 20;
        store.put (two);
        var again = new MachineStore (root);
        again.load ();
        assert (again.items.size == 2);
        assert (again.items[0].name == "Two");
        var found = again.find (m.id);
        assert (found != null && found.name == "One");
        assert (found.dir == Path.build_filename (root, m.id));
        again.remove (found);
        assert (!FileUtils.test (Path.build_filename (root, m.id), FileTest.EXISTS));
        var third = new MachineStore (root);
        third.load ();
        assert (third.items.size == 1);
    });

    Test.add_func ("/host/keyfile", () => {
        var cfg = new HostConfig ();
        var kf = new KeyFile ();
        try {
            kf.load_from_data ("[Machines]\nBackend=libvirt\nQemu=/opt/qemu/bin/qemu-system-x86_64\nFirmwareCode=/fw/CODE.fd\nFirmwareVars=/fw/VARS.fd\nOsinfoPath=/a/osinfo: /b/osinfo\nStorage=/srv/vms\nLibvirtUri=qemu:///system\n", -1, KeyFileFlags.NONE);
        } catch (Error e) {
            assert_not_reached ();
        }
        cfg.apply (kf);
        assert (cfg.backend == "libvirt");
        assert (cfg.qemu == "/opt/qemu/bin/qemu-system-x86_64");
        assert (cfg.firmware_code == "/fw/CODE.fd");
        assert (cfg.firmware_vars == "/fw/VARS.fd");
        assert (cfg.osinfo_dirs.length == 2);
        assert (cfg.osinfo_dirs[1] == "/b/osinfo");
        assert (cfg.storage_dir () == "/srv/vms");
        assert (cfg.libvirt_uri == "qemu:///system");
        assert (HostConfig.split_dirs (":a::b:").length == 2);
    });

    Test.add_func ("/host/osinfo-dirs", () => {
        var cfg = new HostConfig ();
        cfg.osinfo_dirs = { "/custom/osinfo" };
        Environment.set_variable ("OSINFO_SYSTEM_DIR", "/env/osinfo", true);
        string[] dirs = cfg.effective_osinfo_dirs ();
        assert (dirs[0] == "/custom/osinfo");
        assert (dirs[1] == "/env/osinfo");
        Environment.unset_variable ("OSINFO_SYSTEM_DIR");
    });

    Test.add_func ("/host/firmware-descriptors", () => {
        string dir = tmpdir ();
        string code = Path.build_filename (fixtures_dir (), "fw", "CODE.fd");
        string vars = Path.build_filename (fixtures_dir (), "fw", "VARS.fd");
        write_file (Path.build_filename (dir, "10-secure.json"), descriptor (code, vars, "x86_64", "\"requires-smm\", \"secure-boot\""));
        write_file (Path.build_filename (dir, "20-arm.json"), descriptor (code, vars, "aarch64", ""));
        write_file (Path.build_filename (dir, "30-missing.json"), descriptor ("/nonexistent/CODE.fd", vars, "x86_64", ""));
        write_file (Path.build_filename (dir, "35-stateless.json"), "{\"interface-types\": [\"uefi\"], \"mapping\": {\"device\": \"flash\", \"mode\": \"stateless\", \"executable\": {\"filename\": \"%s\"}}, \"targets\": [{\"architecture\": \"x86_64\", \"machines\": [\"pc-q35-*\"]}]}".printf (code));
        write_file (Path.build_filename (dir, "36-sev.json"), descriptor (code, vars, "x86_64", "\"amd-sev\", \"amd-sev-es\""));
        write_file (Path.build_filename (dir, "40-plain.json"), descriptor (code, vars, "x86_64", "\"acpi-s3\""));
        write_file (Path.build_filename (dir, "50-broken.json"), "{ not json");
        var fw = FirmwareIndex.pick ({ dir }, "x86_64");
        assert (fw != null);
        assert (fw.code == code);
        assert (fw.vars == vars);
        assert (fw.source.has_suffix ("40-plain.json"));
        assert (FirmwareIndex.pick ({ dir }, "riscv64") == null);
        FileUtils.unlink (Path.build_filename (dir, "40-plain.json"));
        var only_stateless = FirmwareIndex.pick ({ dir }, "x86_64");
        assert (only_stateless != null && only_stateless.vars == "" && only_stateless.source.has_suffix ("35-stateless.json"));
        var cfg = new HostConfig ();
        cfg.firmware_dirs = { dir };
        cfg.firmware_code = code;
        cfg.firmware_vars = "";
        var direct = cfg.find_firmware ();
        assert (direct != null && direct.code == code && direct.vars == "" && direct.source == "config");
        cfg.firmware_code = "/nonexistent";
        assert (cfg.find_firmware () == null);
    });

    int result = Test.run ();
    Scratch.clean ();
    return result;
}

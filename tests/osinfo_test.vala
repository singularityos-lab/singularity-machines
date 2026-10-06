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

string fake_iso (string name, string volume_id) {
    string path = Path.build_filename (tmpdir (), name);
    var data = new uint8[16 * 2048 + 2048];
    data[16 * 2048] = 1;
    uint8[] magic = "CD001".data;
    for (int i = 0; i < 5; i++) data[16 * 2048 + 1 + i] = magic[i];
    for (int i = 0; i < 32; i++) data[16 * 2048 + 40 + i] = ' ';
    for (int i = 0; i < volume_id.length && i < 32; i++) data[16 * 2048 + 40 + i] = volume_id.data[i];
    try {
        FileUtils.set_data (path, data);
    } catch (Error e) {
        assert_not_reached ();
    }
    return path;
}

HostLimits limits () {
    var l = new HostLimits ();
    l.memory_mib = 16384;
    l.cpus = 8;
    return l;
}

OsDatabase load_db () {
    string fixtures = Environment.get_variable ("FIXTURES") ?? "tests/fixtures";
    var db = new OsDatabase ();
    db.load_dirs ({ Path.build_filename (fixtures, "osinfo"), "/nonexistent/osinfo" });
    return db;
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/osinfo/parse", () => {
        var db = load_db ();
        assert (db.files_read == 3);
        assert (db.entries.size == 3);
        var a = db.find ("http://alpinelinux.org/alpinelinux/3.20");
        assert (a != null);
        assert (a.name == "Alpine Linux 3.20");
        assert (a.vendor == "Alpine Linux Project");
        assert (a.short_id == "alpinelinux3.20");
        assert (a.distro == "alpinelinux");
        assert (a.family == "linux");
        assert (a.recommended_ram == 805306368);
        assert (a.minimum_ram == 134217728);
        assert (a.recommended_storage == 4294967296);
        assert (a.recommended_cpus == 1);
        assert (a.media.size == 2);
        assert (a.media[0].arch == "x86_64");
        assert (!a.efi);
    });

    Test.add_func ("/osinfo/firmware", () => {
        var db = load_db ();
        var w = db.find ("http://microsoft.com/win/11");
        assert (w != null);
        assert (w.efi);
        assert (w.bios_unsupported);
        assert (w.recommended_ram == 4294967296);
    });

    Test.add_func ("/osinfo/match-volume", () => {
        var db = load_db ();
        var m = db.match_volume ("alpine-virt 3.20.3 x86_64", "x86_64");
        assert (m != null && m.version == "3.20");
        m = db.match_volume ("alpine-virt 3.21.0 x86_64", "x86_64");
        assert (m != null && m.version == "3.21");
        assert (db.match_volume ("alpine-virt 3.20.3 x86_64", "aarch64") == null);
        assert (db.match_volume ("alpine-virt 3.20.3 aarch64", "aarch64") != null);
        assert (db.match_volume ("", "x86_64") == null);
        assert (db.match_volume ("something else", "x86_64") == null);
    });

    Test.add_func ("/osinfo/derives-from", () => {
        var db = load_db ();
        var b = db.find ("http://alpinelinux.org/alpinelinux/3.21");
        assert (b.recommended_ram == 0);
        assert (db.resolved_ram (b) == 805306368);
        assert (db.resolved_storage (b) == 4294967296);
        assert (db.resolved_cpus (b) == 1);
    });

    Test.add_func ("/osinfo/latest-of-distro", () => {
        var db = load_db ();
        var l = db.latest_of_distro ("alpinelinux");
        assert (l != null && l.version == "3.21");
        var p = db.latest_of_distro ("alpinelinux", "3.20");
        assert (p != null && p.version == "3.20");
        assert (db.latest_of_distro ("alpinelinux", "3.24") == null);
        assert (db.latest_of_distro ("fedora") == null);
        assert (OsDatabase.compare_versions ("3.10", "3.9") > 0);
        assert (OsDatabase.compare_versions ("3.9", "3.9.0") == 0);
    });

    Test.add_func ("/osinfo/bad-xml", () => {
        var d = new OsDatabase ();
        try {
            d.load_xml ("<libosinfo><os id='x'><name>X</name></libosinfo>");
            assert_not_reached ();
        } catch (MarkupError e) {
        }
    });

    Test.add_func ("/detect/volume-id", () => {
        string iso = fake_iso ("a.iso", "alpine-virt 3.24.2 x86_64");
        assert (Detector.read_volume_id (iso) == "alpine-virt 3.24.2 x86_64");
        string not_iso = Path.build_filename (tmpdir (), "b.iso");
        try {
            FileUtils.set_contents (not_iso, "short");
        } catch (Error e) {
        }
        assert (Detector.read_volume_id (not_iso) == "");
        assert (Detector.read_volume_id ("/nonexistent.iso") == "");
    });

    Test.add_func ("/detect/osinfo-media", () => {
        var db = load_db ();
        var d = Detector.detect (fake_iso ("alpine-virt-3.20.3-x86_64.iso", "alpine-virt 3.20.3 x86_64"), db, "x86_64", limits ());
        assert (d.source == DetectionSource.OSINFO_MEDIA);
        assert (d.os_id == "http://alpinelinux.org/alpinelinux/3.20");
        assert (d.os_name == "Alpine Linux 3.20");
        assert (d.memory_mib == 768);
        assert (d.disk_gib == 4);
        assert (d.cpus == 2);
        assert (!d.is_disk_image);
    });

    Test.add_func ("/detect/osinfo-closest-release", () => {
        var db = load_db ();
        var d = Detector.detect (fake_iso ("alpine.iso", "alpine-virt 3.24.2 x86_64"), db, "x86_64", limits ());
        assert (d.source == DetectionSource.OSINFO_DISTRO);
        assert (d.os_id == "http://alpinelinux.org/alpinelinux/3.21");
        assert (d.os_name == "Alpine Linux 3.24.2");
        assert (d.memory_mib == 768);
    });

    Test.add_func ("/detect/windows", () => {
        var db = load_db ();
        var d = Detector.detect (fake_iso ("Win11_English_x64.iso", "CCCOMA_X64FRE_EN-US_DV9"), db, "x86_64", limits ());
        assert (d.source == DetectionSource.OSINFO_MEDIA);
        assert (d.family == "winnt");
        assert (d.needs_efi);
        assert (d.prefer_efi);
        assert (d.memory_mib == 4096);
        assert (d.disk_gib == 64);
    });

    Test.add_func ("/detect/heuristic", () => {
        string path = Path.build_filename (tmpdir (), "debian-12.5.0-amd64-netinst.iso");
        try {
            FileUtils.set_contents (path, "no volume descriptor");
        } catch (Error e) {
        }
        var d = Detector.detect (path, null, "x86_64", limits ());
        assert (d.source == DetectionSource.HEURISTIC);
        assert (d.os_name == "Debian 12.5.0");
        assert (d.os_id == "debian");
        assert (d.memory_mib == 2048);
        var small = new HostLimits ();
        small.memory_mib = 2048;
        small.cpus = 1;
        var c = Detector.detect (path, null, "x86_64", small);
        assert (c.memory_mib == 1024);
        assert (c.cpus == 1);
    });

    Test.add_func ("/detect/disk-image", () => {
        var db = load_db ();
        string path = Path.build_filename (tmpdir (), "thing.bin");
        try {
            FileUtils.set_data (path, { 'Q', 'F', 'I', 0xfb, 0, 0, 0, 3 });
        } catch (Error e) {
        }
        var d = Detector.detect (path, db, "x86_64", limits ());
        assert (d.is_disk_image);
        assert (d.volume_id == "");
        assert (d.source == DetectionSource.NONE);
        assert (Detector.looks_like_disk_image ("/x/fedora.qcow2"));
        assert (Detector.version_in ("alpine-cloud-disk") == null);
        assert (Detector.version_in ("debian-12.5.0-amd64") == "12.5.0");
        assert (Detector.version_in ("alpine-virt 3.24.2 x86_64") == "3.24.2");
        string img = Path.build_filename (tmpdir (), "alpine-cloud-disk.qcow2");
        try {
            FileUtils.set_data (img, { 'Q', 'F', 'I', 0xfb });
        } catch (Error e) {
        }
        var a = Detector.detect (img, db, "x86_64", limits ());
        assert (a.is_disk_image);
        assert (a.source == DetectionSource.OSINFO_DISTRO);
        assert (a.os_name == "Alpine Linux");
        assert (!Detector.looks_like_disk_image ("/nonexistent/fedora.iso"));
    });

    Test.add_func ("/detect/unknown", () => {
        var db = load_db ();
        var d = Detector.detect (fake_iso ("mystery.iso", "CDROM"), db, "x86_64", limits ());
        assert (d.source == DetectionSource.NONE);
        assert (d.os_name == "");
        assert (d.memory_mib == 2048);
        assert (d.disk_gib == 20);
    });

    int result = Test.run ();
    Scratch.clean ();
    return result;
}

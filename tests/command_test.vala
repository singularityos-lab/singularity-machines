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

int index_of (string[] argv, string value) {
    for (int i = 0; i < argv.length; i++) {
        if (argv[i] == value) return i;
    }
    return -1;
}

bool has_pair (string[] argv, string flag, string value) {
    for (int i = 0; i + 1 < argv.length; i++) {
        if (argv[i] == flag && argv[i + 1] == value) return true;
    }
    return false;
}

bool has_prefix_pair (string[] argv, string flag, string prefix) {
    for (int i = 0; i + 1 < argv.length; i++) {
        if (argv[i] == flag && argv[i + 1].has_prefix (prefix)) return true;
    }
    return false;
}

Machine sample () {
    var m = new Machine ();
    m.id = "0badcafe";
    m.name = "Alpine";
    m.dir = "/data/machines/0badcafe";
    m.memory_mib = 1024;
    m.cpus = 2;
    m.install_media = "/images/alpine-virt.iso";
    return m;
}

RuntimePaths runtime () {
    return new RuntimePaths ("/run/user/1000/machines-0badcafe");
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/command/kvm-linux", () => {
        var rt = runtime ();
        var cmd = new QemuCommand ();
        cmd.binary = "/usr/bin/qemu-system-x86_64";
        cmd.kvm = true;
        string[] a = cmd.build (sample (), rt);
        assert (a[0] == "/usr/bin/qemu-system-x86_64");
        assert (has_pair (a, "-accel", "kvm"));
        assert (has_pair (a, "-cpu", "host"));
        assert (has_pair (a, "-machine", "q35,vmport=off"));
        assert (has_pair (a, "-m", "1024"));
        assert (has_pair (a, "-smp", "2"));
        assert (has_pair (a, "-display", "none"));
        assert (has_pair (a, "-vnc", "unix:/run/user/1000/machines-0badcafe/vnc"));
        assert (has_pair (a, "-qmp", "unix:/run/user/1000/machines-0badcafe/qmp,server=on,wait=off"));
        assert (has_pair (a, "-pidfile", "/run/user/1000/machines-0badcafe/pid"));
        assert (index_of (a, "-daemonize") > 0);
        assert (index_of (a, "-nodefaults") > 0);
        assert (has_pair (a, "-name", "Alpine,process=machines-0badcafe"));
        assert (has_pair (a, "-drive", "file=/data/machines/0badcafe/disk.qcow2,if=none,id=disk0,format=qcow2,discard=unmap"));
        assert (has_pair (a, "-device", "virtio-blk-pci,drive=disk0,bootindex=1"));
        assert (has_pair (a, "-drive", "file=/images/alpine-virt.iso,if=none,id=cd0,media=cdrom,readonly=on"));
        assert (has_pair (a, "-device", "ide-cd,drive=cd0,bus=ide.1,id=cdrom0,bootindex=0"));
        assert (has_pair (a, "-device", "virtio-vga,id=video0"));
        assert (has_pair (a, "-device", "usb-tablet,bus=xhci.0,id=tablet"));
        assert (has_pair (a, "-nic", "user,model=virtio-net-pci"));
        assert (has_pair (a, "-chardev", "qemu-vdagent,id=vdagent,clipboard=on"));
        assert (index_of (a, "-virtfs") < 0);
        assert (index_of (a, "-loadvm") < 0);
        assert (!has_prefix_pair (a, "-drive", "if=pflash"));
    });

    Test.add_func ("/command/tcg", () => {
        var rt = runtime ();
        var cmd = new QemuCommand ();
        cmd.kvm = false;
        cmd.daemonize = false;
        string[] a = cmd.build (sample (), rt);
        assert (has_pair (a, "-accel", "tcg"));
        assert (has_pair (a, "-cpu", "max"));
        assert (index_of (a, "-daemonize") < 0);
    });

    Test.add_func ("/command/uefi", () => {
        var rt = runtime ();
        var m = sample ();
        m.uefi = true;
        var fw = new Firmware ();
        fw.code = "/usr/share/OVMF/OVMF_CODE_4M.fd";
        fw.vars = "/usr/share/OVMF/OVMF_VARS_4M.fd";
        var cmd = new QemuCommand ();
        cmd.firmware = fw;
        string[] a = cmd.build (m, rt);
        assert (has_pair (a, "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd"));
        assert (has_pair (a, "-drive", "if=pflash,format=qcow2,unit=1,file=/data/machines/0badcafe/efivars.qcow2"));
        fw.vars = "";
        a = cmd.build (m, rt);
        assert (!has_prefix_pair (a, "-drive", "if=pflash,format=qcow2"));
        m.uefi = false;
        fw.vars = "/x";
        a = cmd.build (m, rt);
        assert (!has_prefix_pair (a, "-drive", "if=pflash"));
    });

    Test.add_func ("/command/escaping", () => {
        var rt = runtime ();
        var m = sample ();
        m.name = "A, B";
        m.dir = "/data/odd,dir";
        m.install_media = "/images/x,y.iso";
        string[] a = new QemuCommand ().build (m, rt);
        assert (has_pair (a, "-name", "A,, B,process=machines-0badcafe"));
        assert (has_pair (a, "-drive", "file=/data/odd,,dir/disk.qcow2,if=none,id=disk0,format=qcow2,discard=unmap"));
        assert (has_pair (a, "-drive", "file=/images/x,,y.iso,if=none,id=cd0,media=cdrom,readonly=on"));
    });

    Test.add_func ("/command/windows", () => {
        var rt = runtime ();
        var m = sample ();
        m.family = "winnt";
        string[] a = new QemuCommand ().build (m, rt);
        assert (has_pair (a, "-device", "VGA,id=video0"));
        assert (has_pair (a, "-device", "ide-hd,drive=disk0,bus=ide.0,bootindex=1"));
        assert (has_pair (a, "-nic", "user,model=e1000e"));
        assert (has_pair (a, "-rtc", "base=localtime"));
        assert (has_pair (a, "-device", "usb-kbd,bus=xhci.0,id=keyboard"));
    });

    Test.add_func ("/command/shared-folder", () => {
        var rt = runtime ();
        var m = sample ();
        m.shared_folder = "/home/me/Share";
        var cmd = new QemuCommand ();
        cmd.shared = SharedMode.VIRTIOFS;
        string[] a = cmd.build (m, rt);
        assert (has_pair (a, "-object", "memory-backend-memfd,id=mem,size=1024M,share=on"));
        assert (has_pair (a, "-numa", "node,memdev=mem"));
        assert (has_pair (a, "-chardev", "socket,id=fs0,path=/run/user/1000/machines-0badcafe/fs"));
        assert (has_pair (a, "-device", "vhost-user-fs-pci,chardev=fs0,tag=shared"));
        cmd.shared = SharedMode.NINEP;
        a = cmd.build (m, rt);
        assert (has_pair (a, "-virtfs", "local,path=/home/me/Share,mount_tag=shared,security_model=mapped-xattr,id=fs0"));
        assert (index_of (a, "-numa") < 0);
        cmd.shared = SharedMode.NONE;
        a = cmd.build (m, rt);
        assert (index_of (a, "-virtfs") < 0);
        string[] v = QemuCommand.virtiofsd_args ("/usr/libexec/virtiofsd", rt.fs_socket, m.shared_folder);
        assert (v[1] == "--socket-path=/run/user/1000/machines-0badcafe/fs");
        assert (v[2] == "--shared-dir=/home/me/Share");
    });

    Test.add_func ("/command/tpm", () => {
        var rt = runtime ();
        var m = sample ();
        var cmd = new QemuCommand ();
        string[] a = cmd.build (m, rt);
        assert (index_of (a, "-tpmdev") < 0);
        cmd.tpm = true;
        a = cmd.build (m, rt);
        assert (has_pair (a, "-chardev", "socket,id=tpm0chr,path=/run/user/1000/machines-0badcafe/tpm"));
        assert (has_pair (a, "-tpmdev", "emulator,id=tpm0,chardev=tpm0chr"));
        assert (has_pair (a, "-device", "tpm-tis,tpmdev=tpm0"));
        cmd.arch = "aarch64";
        a = cmd.build (m, rt);
        assert (has_pair (a, "-device", "tpm-tis-device,tpmdev=tpm0"));
        string[] s = QemuCommand.swtpm_args ("swtpm", rt.tpm_socket, m.tpm_state_dir (), rt.tpm_pid);
        assert (has_pair (s, "--tpmstate", "dir=/data/machines/0badcafe/tpm"));
        assert (has_pair (s, "--ctrl", "type=unixio,path=/run/user/1000/machines-0badcafe/tpm"));
        assert (index_of (s, "--terminate") > 0 && index_of (s, "--daemon") > 0);
    });

    Test.add_func ("/command/loadvm-and-media", () => {
        var rt = runtime ();
        var m = sample ();
        m.install_media = "";
        var cmd = new QemuCommand ();
        cmd.loadvm = "snap-1";
        string[] a = cmd.build (m, rt);
        assert (has_pair (a, "-loadvm", "snap-1"));
        assert (!has_prefix_pair (a, "-drive", "file=/images"));
    });

    Test.add_func ("/command/aarch64", () => {
        var rt = runtime ();
        var cmd = new QemuCommand ();
        cmd.arch = "aarch64";
        string[] a = cmd.build (sample (), rt);
        assert (has_pair (a, "-machine", "virt"));
    });

    Test.add_func ("/command/runtime-paths", () => {
        var rt = runtime ();
        assert (rt.fits ());
        var p = RuntimePaths.for_machine ("/run/user/1000", "0badcafe");
        assert (p.dir == "/run/user/1000/machines-0badcafe");
        var long_rt = new RuntimePaths ("/" + string.nfill (120, 'x'));
        assert (!long_rt.fits ());
    });

    Test.add_func ("/command/qemu-img", () => {
        string[] c = QemuCommand.create_disk_args ("qemu-img", "/d/disk.qcow2", 20);
        assert (c[1] == "create" && c[c.length - 1] == "20G" && c[c.length - 2] == "/d/disk.qcow2");
        string[] i = QemuCommand.import_disk_args ("qemu-img", "/src/a.vmdk", "/d/disk.qcow2");
        assert (i[1] == "convert" && index_of (i, "qcow2") > 0 && i[i.length - 2] == "/src/a.vmdk");
        var fw = new Firmware ();
        fw.vars = "/fw/VARS.fd";
        string[] v = QemuCommand.vars_args ("qemu-img", fw, "/d/efivars.qcow2");
        assert (v[v.length - 2] == "/fw/VARS.fd" && v[v.length - 1] == "/d/efivars.qcow2");
    });

    Test.add_func ("/libvirt/domain-xml", () => {
        var rt = runtime ();
        var m = sample ();
        m.name = "Tom & Jerry";
        m.shared_folder = "/home/me/Share";
        string xml = DomainXml.build (m, null, rt, true, "x86_64");
        assert (xml.contains ("<name>singularity-machines-0badcafe</name>"));
        assert (xml.contains ("<title>Tom &amp; Jerry</title>"));
        assert (xml.contains ("<domain type='kvm'>"));
        assert (xml.contains ("<graphics type='vnc' socket='/run/user/1000/machines-0badcafe/vnc'/>"));
        assert (xml.contains ("<memory unit='MiB'>1024</memory>"));
        assert (xml.contains ("<driver type='virtiofs'/>"));
        assert (xml.contains ("device='cdrom'"));
        var fw = new Firmware ();
        fw.code = "/fw/CODE.fd";
        fw.vars = "/fw/VARS.fd";
        m.uefi = true;
        xml = DomainXml.build (m, fw, rt, false, "x86_64");
        assert (xml.contains ("<domain type='qemu'>"));
        assert (xml.contains ("<loader readonly='yes' type='pflash'>/fw/CODE.fd</loader>"));
        assert (xml.contains ("template='/fw/VARS.fd'"));
        var d = new UsbDevice ();
        d.bus = 3;
        d.address = 7;
        assert (DomainXml.hostdev (d).contains ("<address bus='3' device='7'/>"));
        assert (d.qdev_id () == "usb-003-007");
    });

    Test.add_func ("/usb/sysfs", () => {
        string root = Scratch.make ();
        string dev = Path.build_filename (root, "1-2");
        string hub = Path.build_filename (root, "usb1");
        string iface = Path.build_filename (root, "1-2:1.0");
        DirUtils.create (dev, 0755);
        DirUtils.create (hub, 0755);
        DirUtils.create (iface, 0755);
        try {
            FileUtils.set_contents (Path.build_filename (dev, "busnum"), "1\n");
            FileUtils.set_contents (Path.build_filename (dev, "devnum"), "5\n");
            FileUtils.set_contents (Path.build_filename (dev, "idVendor"), "046d\n");
            FileUtils.set_contents (Path.build_filename (dev, "idProduct"), "c52b\n");
            FileUtils.set_contents (Path.build_filename (dev, "manufacturer"), "Logitech\n");
            FileUtils.set_contents (Path.build_filename (dev, "product"), "USB Receiver\n");
            FileUtils.set_contents (Path.build_filename (dev, "bDeviceClass"), "00\n");
        } catch (Error e) {
            assert_not_reached ();
        }
        var list = UsbDevice.list (root);
        assert (list.size == 1);
        assert (list[0].label == "Logitech USB Receiver");
        assert (list[0].bus == 1 && list[0].address == 5);
        assert (list[0].vendor_id == "046d");
    });

    Test.add_func ("/backend/choose", () => {
        var host = new HostConfig ();
        host.qemu = "/nonexistent/qemu";
        host.backend = "qemu";
        var b = Backends.choose (host);
        assert (b.id == "qemu");
        assert (!b.available ());
        assert (b.unavailable_reason () != "");
    });

    Test.add_func ("/tool/tidy", () => {
        assert (Tool.tidy ("qemu-system-x86_64: -drive x: Could not open 'x'\n", "/usr/bin/qemu-system-x86_64") == "-drive x: Could not open 'x'");
        assert (Tool.tidy ("", "qemu-img") != "");
    });

    int result = Test.run ();
    Scratch.clean ();
    return result;
}

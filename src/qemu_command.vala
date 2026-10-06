namespace Singularity.Apps.Machines {

    public enum SharedMode {
        NONE,
        VIRTIOFS,
        NINEP
    }

    public class RuntimePaths : Object {
        public string dir { get; construct; }

        public RuntimePaths (string dir) {
            Object (dir: dir);
        }

        public static RuntimePaths for_machine (string runtime_root, string id) {
            return new RuntimePaths (Path.build_filename (runtime_root, "machines-" + id));
        }

        public string qmp { owned get { return Path.build_filename (dir, "qmp"); } }
        public string vnc { owned get { return Path.build_filename (dir, "vnc"); } }
        public string pid { owned get { return Path.build_filename (dir, "pid"); } }
        public string fs_socket { owned get { return Path.build_filename (dir, "fs"); } }
        public string fs_pid { owned get { return Path.build_filename (dir, "fs.pid"); } }
        public string log { owned get { return Path.build_filename (dir, "log"); } }

        public bool fits () {
            return qmp.length < 108 && vnc.length < 108 && fs_socket.length < 108;
        }
    }

    public class QemuCommand : Object {
        public string binary { get; set; default = "qemu-system-x86_64"; }
        public string arch { get; set; default = "x86_64"; }
        public bool kvm { get; set; }
        public Firmware? firmware { get; set; }
        public SharedMode shared { get; set; default = SharedMode.NONE; }
        public string loadvm { get; set; default = ""; }
        public bool daemonize { get; set; default = true; }
        public bool clipboard_agent { get; set; default = true; }

        public static string escape (string value) {
            return value.replace (",", ",,");
        }

        public string[] build (Machine m, RuntimePaths rt) {
            string[] a = { binary };
            bool windows = m.family == "winnt";
            a += "-name";
            a += "%s,process=machines-%s".printf (escape (m.title ()), m.id);
            a += "-nodefaults";
            a += "-no-user-config";
            if (arch == "aarch64") {
                a += "-machine";
                a += "virt";
            } else {
                a += "-machine";
                a += "q35,vmport=off";
            }
            a += "-accel";
            a += kvm ? "kvm" : "tcg";
            a += "-cpu";
            a += kvm ? "host" : "max";
            a += "-smp";
            a += "%d".printf (m.cpus);
            a += "-m";
            a += "%d".printf (m.memory_mib);
            if (shared == SharedMode.VIRTIOFS) {
                a += "-object";
                a += "memory-backend-memfd,id=mem,size=%dM,share=on".printf (m.memory_mib);
                a += "-numa";
                a += "node,memdev=mem";
            }
            if (m.uefi && firmware != null) {
                a += "-drive";
                a += "if=pflash,format=%s,unit=0,readonly=on,file=%s".printf (firmware.code_format, escape (firmware.code));
                if (firmware.vars != "") {
                    a += "-drive";
                    a += "if=pflash,format=qcow2,unit=1,file=%s".printf (escape (m.vars_path ()));
                }
            }
            a += "-display";
            a += "none";
            a += "-vnc";
            a += "unix:%s".printf (rt.vnc);
            a += "-qmp";
            a += "unix:%s,server=on,wait=off".printf (rt.qmp);
            a += "-pidfile";
            a += rt.pid;
            if (daemonize) a += "-daemonize";
            a += "-device";
            a += windows ? "VGA,id=video0" : "virtio-vga,id=video0";
            a += "-device";
            a += "qemu-xhci,id=xhci";
            a += "-device";
            a += "usb-tablet,bus=xhci.0,id=tablet";
            if (windows) {
                a += "-device";
                a += "usb-kbd,bus=xhci.0,id=keyboard";
            }
            a += "-nic";
            a += windows ? "user,model=e1000e" : "user,model=virtio-net-pci";
            a += "-device";
            a += "virtio-rng-pci";
            a += "-drive";
            a += "file=%s,if=none,id=disk0,format=qcow2,discard=unmap".printf (escape (m.disk_path ()));
            a += "-device";
            a += windows ? "ide-hd,drive=disk0,bus=ide.0,bootindex=1" : "virtio-blk-pci,drive=disk0,bootindex=1";
            if (m.install_media != "") {
                a += "-drive";
                a += "file=%s,if=none,id=cd0,media=cdrom,readonly=on".printf (escape (m.install_media));
                a += "-device";
                a += "ide-cd,drive=cd0,bus=ide.1,id=cdrom0,bootindex=0";
            }
            if (clipboard_agent) {
                a += "-device";
                a += "virtio-serial-pci,id=serial0";
                a += "-chardev";
                a += "qemu-vdagent,id=vdagent,clipboard=on";
                a += "-device";
                a += "virtserialport,bus=serial0.0,chardev=vdagent,name=com.redhat.spice.0";
            }
            if (m.shared_folder != "" && shared == SharedMode.VIRTIOFS) {
                a += "-chardev";
                a += "socket,id=fs0,path=%s".printf (escape (rt.fs_socket));
                a += "-device";
                a += "vhost-user-fs-pci,chardev=fs0,tag=shared";
            } else if (m.shared_folder != "" && shared == SharedMode.NINEP) {
                a += "-virtfs";
                a += "local,path=%s,mount_tag=shared,security_model=mapped-xattr,id=fs0".printf (escape (m.shared_folder));
            }
            if (windows) {
                a += "-rtc";
                a += "base=localtime";
            }
            if (loadvm != "") {
                a += "-loadvm";
                a += loadvm;
            }
            return a;
        }

        public static string[] virtiofsd_args (string binary, string socket, string folder) {
            return { binary, "--socket-path=" + socket, "--shared-dir=" + folder, "--sandbox=none", "--cache=auto" };
        }

        public static string[] create_disk_args (string qemu_img, string path, int gib) {
            return { qemu_img, "create", "-q", "-f", "qcow2", path, "%dG".printf (gib) };
        }

        public static string[] import_disk_args (string qemu_img, string source, string path) {
            return { qemu_img, "convert", "-p", "-O", "qcow2", source, path };
        }

        public static string[] vars_args (string qemu_img, Firmware fw, string path) {
            return { qemu_img, "convert", "-q", "-f", fw.vars_format, "-O", "qcow2", fw.vars, path };
        }
    }
}

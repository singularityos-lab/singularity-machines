namespace Singularity.Apps.Machines {

    [CCode (cname = "MACHINES_SYSCONFDIR")]
    extern const string SYSCONFDIR;
    [CCode (cname = "MACHINES_DATADIR")]
    extern const string DATADIR;
    [CCode (cname = "MACHINES_DEFAULT_BACKEND")]
    extern const string DEFAULT_BACKEND;
    [CCode (cname = "MACHINES_DEFAULT_QEMU")]
    extern const string DEFAULT_QEMU;
    [CCode (cname = "MACHINES_FIRMWARE_DIRS")]
    extern const string DEFAULT_FIRMWARE_DIRS;
    [CCode (cname = "MACHINES_OSINFO_DIRS")]
    extern const string DEFAULT_OSINFO_DIRS;

    public class Firmware : Object {
        public string code { get; set; default = ""; }
        public string code_format { get; set; default = "raw"; }
        public string vars { get; set; default = ""; }
        public string vars_format { get; set; default = "raw"; }
        public string source { get; set; default = ""; }
    }

    public class HostConfig : Object {
        public string backend { get; set; default = "auto"; }
        public string qemu { get; set; default = ""; }
        public string qemu_img { get; set; default = "qemu-img"; }
        public string virtiofsd { get; set; default = ""; }
        public string virsh { get; set; default = "virsh"; }
        public string libvirt_uri { get; set; default = "qemu:///session"; }
        public string firmware_code { get; set; default = ""; }
        public string firmware_vars { get; set; default = ""; }
        public string storage { get; set; default = ""; }
        public string kvm_device { get; set; default = "/dev/kvm"; }
        public string usb_root { get; set; default = "/sys/bus/usb/devices"; }
        public string arch { get; set; default = "x86_64"; }
        public string[] firmware_dirs = {};
        public string[] osinfo_dirs = {};
        public string[] loaded_files = {};

        private const string GROUP = "Machines";

        public HostConfig () {
            arch = host_arch ();
            backend = DEFAULT_BACKEND;
            qemu = DEFAULT_QEMU;
            firmware_dirs = split_dirs (DEFAULT_FIRMWARE_DIRS);
            osinfo_dirs = split_dirs (DEFAULT_OSINFO_DIRS);
        }

        public static string host_arch () {
            var u = Posix.utsname ();
            string m = u.machine;
            if (m == "amd64") return "x86_64";
            if (m == "arm64") return "aarch64";
            return m != "" ? m : "x86_64";
        }

        public static string[] split_dirs (string text) {
            string[] result = {};
            foreach (string part in text.split (":")) {
                string p = part.strip ();
                if (p != "") result += p;
            }
            return result;
        }

        public static string[] config_files () {
            string[] files = {
                Path.build_filename (SYSCONFDIR, "singularity", "machines.conf"),
                Path.build_filename (Environment.get_user_config_dir (), "singularity", "machines.conf")
            };
            string? extra = Environment.get_variable ("SINGULARITY_MACHINES_CONF");
            if (extra != null && extra != "") files += extra;
            return files;
        }

        public static HostConfig load () {
            var cfg = new HostConfig ();
            foreach (string path in config_files ()) {
                if (!FileUtils.test (path, FileTest.IS_REGULAR)) continue;
                var kf = new KeyFile ();
                try {
                    kf.load_from_file (path, KeyFileFlags.NONE);
                    cfg.apply (kf);
                    string[] files = cfg.loaded_files;
                    files += path;
                    cfg.loaded_files = files;
                } catch (Error e) {
                    warning ("machines: %s: %s", path, e.message);
                }
            }
            return cfg;
        }

        private static string? get_str (KeyFile kf, string key) {
            try {
                if (kf.has_key (GROUP, key)) return kf.get_string (GROUP, key).strip ();
            } catch (Error e) {
            }
            return null;
        }

        public void apply (KeyFile kf) {
            string? v;
            if ((v = get_str (kf, "Backend")) != null && v != "") backend = v;
            if ((v = get_str (kf, "Qemu")) != null && v != "") qemu = v;
            if ((v = get_str (kf, "QemuImg")) != null && v != "") qemu_img = v;
            if ((v = get_str (kf, "Virtiofsd")) != null && v != "") virtiofsd = v;
            if ((v = get_str (kf, "Virsh")) != null && v != "") virsh = v;
            if ((v = get_str (kf, "LibvirtUri")) != null && v != "") libvirt_uri = v;
            if ((v = get_str (kf, "FirmwareCode")) != null) firmware_code = v;
            if ((v = get_str (kf, "FirmwareVars")) != null) firmware_vars = v;
            if ((v = get_str (kf, "Storage")) != null) storage = v;
            if ((v = get_str (kf, "KvmDevice")) != null && v != "") kvm_device = v;
            if ((v = get_str (kf, "UsbDevices")) != null && v != "") usb_root = v;
            if ((v = get_str (kf, "FirmwareDescriptors")) != null && v != "") firmware_dirs = split_dirs (v);
            if ((v = get_str (kf, "OsinfoPath")) != null && v != "") osinfo_dirs = split_dirs (v);
        }

        public static string? resolve (string program) {
            if (program == "") return null;
            if (Path.is_absolute (program)) return FileUtils.test (program, FileTest.IS_EXECUTABLE) ? program : null;
            return Environment.find_program_in_path (program);
        }

        public string? qemu_binary () {
            return resolve (qemu != "" ? qemu : "qemu-system-" + arch);
        }

        public string? qemu_img_binary () {
            return resolve (qemu_img);
        }

        public string? virsh_binary () {
            return resolve (virsh);
        }

        public string? virtiofsd_binary () {
            if (virtiofsd != "") return resolve (virtiofsd);
            foreach (string p in new string[] { "/usr/libexec/virtiofsd", "/usr/lib/virtiofsd", "/usr/lib/qemu/virtiofsd", "/usr/local/libexec/virtiofsd" }) {
                if (FileUtils.test (p, FileTest.IS_EXECUTABLE)) return p;
            }
            return Environment.find_program_in_path ("virtiofsd");
        }

        public bool kvm_available () {
            return FileUtils.test (kvm_device, FileTest.EXISTS) && Posix.access (kvm_device, Posix.R_OK | Posix.W_OK) == 0;
        }

        public string storage_dir () {
            if (storage != "") return storage;
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-machines");
        }

        public string runtime_root () {
            return Environment.get_user_runtime_dir ();
        }

        public string[] effective_osinfo_dirs () {
            string[] dirs = {};
            foreach (string d in osinfo_dirs) dirs += d;
            string? sys = Environment.get_variable ("OSINFO_SYSTEM_DIR");
            if (sys != null && sys != "") dirs += sys;
            if (osinfo_dirs.length == 0 && (sys == null || sys == "")) {
                dirs += Path.build_filename (DATADIR, "osinfo");
                if (DATADIR != "/usr/share") dirs += "/usr/share/osinfo";
                dirs += "/usr/share/libosinfo/db";
            }
            string? local = Environment.get_variable ("OSINFO_LOCAL_DIR");
            dirs += local != null && local != "" ? local : Path.build_filename (SYSCONFDIR, "osinfo");
            string? user = Environment.get_variable ("OSINFO_USER_DIR");
            dirs += user != null && user != "" ? user : Path.build_filename (Environment.get_user_config_dir (), "osinfo");
            return dirs;
        }

        public string[] effective_firmware_dirs () {
            if (firmware_dirs.length > 0) return firmware_dirs;
            return {
                Path.build_filename (Environment.get_user_config_dir (), "qemu", "firmware"),
                Path.build_filename (SYSCONFDIR, "qemu", "firmware"),
                Path.build_filename (DATADIR, "qemu", "firmware"),
                "/usr/share/qemu/firmware"
            };
        }

        public Firmware? find_firmware () {
            if (firmware_code != "") {
                if (!FileUtils.test (firmware_code, FileTest.IS_REGULAR)) return null;
                var f = new Firmware ();
                f.code = firmware_code;
                f.vars = FileUtils.test (firmware_vars, FileTest.IS_REGULAR) ? firmware_vars : "";
                f.source = "config";
                return f;
            }
            var fw = FirmwareIndex.pick (effective_firmware_dirs (), arch);
            if (fw != null) return fw;
            return FirmwareIndex.fallback (arch);
        }
    }

    namespace FirmwareIndex {
        public Firmware? pick (string[] dirs, string arch) {
            var seen = new Gee.HashMap<string, string> ();
            foreach (string dir in dirs) {
                try {
                    var d = Dir.open (dir);
                    string? name;
                    while ((name = d.read_name ()) != null) {
                        if (!name.has_suffix (".json") || seen.has_key (name)) continue;
                        seen[name] = Path.build_filename (dir, name);
                    }
                } catch (Error e) {
                }
            }
            var names = new Gee.ArrayList<string> ();
            names.add_all (seen.keys);
            names.sort ((a, b) => strcmp (a, b));
            Firmware? stateless = null;
            foreach (string name in names) {
                var fw = parse (seen[name], arch);
                if (fw == null) continue;
                if (fw.vars != "") return fw;
                if (stateless == null) stateless = fw;
            }
            return stateless;
        }

        private bool has_string (Json.Array? arr, string value) {
            if (arr == null) return false;
            for (uint i = 0; i < arr.get_length (); i++) {
                if (arr.get_string_element (i) == value) return true;
            }
            return false;
        }

        public Firmware? parse (string path, string arch) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ().get_object ();
                if (!has_string (root.get_array_member ("interface-types"), "uefi")) return null;
                var features = root.has_member ("features") ? root.get_array_member ("features") : null;
                foreach (string f in new string[] { "requires-smm", "secure-boot", "enrolled-keys", "amd-sev-es", "amd-sev-snp", "intel-tdx" }) {
                    if (has_string (features, f)) return null;
                }
                var mapping = root.get_object_member ("mapping");
                if (mapping == null || mapping.get_string_member_with_default ("device", "") != "flash") return null;
                bool arch_ok = false;
                var targets = root.get_array_member ("targets");
                for (uint i = 0; targets != null && i < targets.get_length (); i++) {
                    var t = targets.get_object_element (i);
                    if (t.get_string_member_with_default ("architecture", "") != arch) continue;
                    var machines = t.get_array_member ("machines");
                    for (uint j = 0; machines != null && j < machines.get_length (); j++) {
                        string m = machines.get_string_element (j);
                        if (m.has_prefix ("pc-q35") || m.has_prefix ("virt")) arch_ok = true;
                    }
                }
                if (!arch_ok) return null;
                var exe = mapping.get_object_member ("executable");
                if (exe == null) return null;
                var fw = new Firmware ();
                fw.code = exe.get_string_member_with_default ("filename", "");
                fw.code_format = exe.get_string_member_with_default ("format", "raw");
                if (mapping.has_member ("nvram-template")) {
                    var nv = mapping.get_object_member ("nvram-template");
                    fw.vars = nv.get_string_member_with_default ("filename", "");
                    fw.vars_format = nv.get_string_member_with_default ("format", "raw");
                }
                if (fw.code == "" || !FileUtils.test (fw.code, FileTest.IS_REGULAR)) return null;
                if (fw.vars != "" && !FileUtils.test (fw.vars, FileTest.IS_REGULAR)) return null;
                fw.source = path;
                return fw;
            } catch (Error e) {
                return null;
            }
        }

        public Firmware? fallback (string arch) {
            string[,] pairs = {
                { "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd" },
                { "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd" },
                { "/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd" },
                { "/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd" },
                { "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd", "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd" },
                { "/usr/share/qemu/edk2-x86_64-code.fd", "/usr/share/qemu/edk2-i386-vars.fd" }
            };
            if (arch != "x86_64") return null;
            for (int i = 0; i < pairs.length[0]; i++) {
                if (FileUtils.test (pairs[i, 0], FileTest.IS_REGULAR) && FileUtils.test (pairs[i, 1], FileTest.IS_REGULAR)) {
                    var fw = new Firmware ();
                    fw.code = pairs[i, 0];
                    fw.vars = pairs[i, 1];
                    fw.source = "builtin";
                    return fw;
                }
            }
            return null;
        }
    }
}

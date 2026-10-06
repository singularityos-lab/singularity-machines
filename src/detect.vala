namespace Singularity.Apps.Machines {

    public enum DetectionSource {
        NONE,
        OSINFO_MEDIA,
        OSINFO_DISTRO,
        HEURISTIC
    }

    public class Detection : Object {
        public string os_id { get; set; default = ""; }
        public string os_name { get; set; default = ""; }
        public string family { get; set; default = "linux"; }
        public string volume_id { get; set; default = ""; }
        public bool is_disk_image { get; set; }
        public DetectionSource source { get; set; default = DetectionSource.NONE; }
        public int memory_mib { get; set; default = 2048; }
        public int cpus { get; set; default = 2; }
        public int disk_gib { get; set; default = 20; }
        public bool prefer_efi { get; set; }
        public bool needs_efi { get; set; }
    }

    public class HostLimits : Object {
        public int64 memory_mib { get; set; default = 8192; }
        public int cpus { get; set; default = 4; }

        public static HostLimits read () {
            var l = new HostLimits ();
            l.cpus = (int) get_num_processors ();
            try {
                string meminfo;
                FileUtils.get_contents ("/proc/meminfo", out meminfo);
                foreach (string line in meminfo.split ("\n")) {
                    if (line.has_prefix ("MemTotal:")) {
                        string kb = line.substring (9).strip ().split (" ")[0];
                        l.memory_mib = int64.parse (kb) / 1024;
                    }
                }
            } catch (Error e) {
            }
            return l;
        }
    }

    namespace Detector {
        private struct Hint {
            string key;
            string distro;
            string name;
            string family;
            int memory;
            int cpus;
            int disk;
            bool efi;
        }

        private const Hint[] HINTS = {
            { "alpine", "alpinelinux", "Alpine Linux", "linux", 1024, 1, 8, false },
            { "ubuntu", "ubuntu", "Ubuntu", "linux", 4096, 2, 25, true },
            { "kubuntu", "ubuntu", "Kubuntu", "linux", 4096, 2, 25, true },
            { "debian", "debian", "Debian", "linux", 2048, 2, 20, false },
            { "fedora", "fedora", "Fedora", "linux", 4096, 2, 25, true },
            { "archlinux", "archlinux", "Arch Linux", "linux", 2048, 2, 20, false },
            { "arch", "archlinux", "Arch Linux", "linux", 2048, 2, 20, false },
            { "opensuse", "opensuse", "openSUSE", "linux", 4096, 2, 25, false },
            { "linuxmint", "mint", "Linux Mint", "linux", 4096, 2, 25, false },
            { "mint", "mint", "Linux Mint", "linux", 4096, 2, 25, false },
            { "manjaro", "manjaro", "Manjaro", "linux", 4096, 2, 30, false },
            { "pop_os", "popos", "Pop!_OS", "linux", 4096, 2, 30, true },
            { "pop-os", "popos", "Pop!_OS", "linux", 4096, 2, 30, true },
            { "elementary", "elementary", "elementary OS", "linux", 4096, 2, 25, false },
            { "centos", "centos", "CentOS", "linux", 2048, 2, 20, false },
            { "rocky", "rocky", "Rocky Linux", "linux", 2048, 2, 20, false },
            { "almalinux", "almalinux", "AlmaLinux", "linux", 2048, 2, 20, false },
            { "nixos", "nixos", "NixOS", "linux", 4096, 2, 25, false },
            { "void", "voidlinux", "Void Linux", "linux", 2048, 2, 15, false },
            { "gentoo", "gentoo", "Gentoo", "linux", 2048, 2, 30, false },
            { "kali", "kali", "Kali Linux", "linux", 2048, 2, 25, false },
            { "vanilla", "vanillaos", "Vanilla OS", "linux", 4096, 2, 50, true },
            { "tinycore", "tinycore", "Tiny Core Linux", "linux", 256, 1, 2, false },
            { "corepure64", "tinycore", "Tiny Core Linux", "linux", 256, 1, 2, false },
            { "core-current", "tinycore", "Tiny Core Linux", "linux", 256, 1, 2, false },
            { "freebsd", "freebsd", "FreeBSD", "bsd", 2048, 2, 20, false },
            { "openbsd", "openbsd", "OpenBSD", "bsd", 1024, 1, 16, false },
            { "netbsd", "netbsd", "NetBSD", "bsd", 1024, 1, 16, false },
            { "win11", "win", "Windows 11", "winnt", 4096, 2, 64, true },
            { "win10", "win", "Windows 10", "winnt", 4096, 2, 64, false },
            { "windows", "win", "Windows", "winnt", 4096, 2, 64, true },
            { "ccsa", "win", "Windows", "winnt", 4096, 2, 64, true },
            { "cpba", "win", "Windows", "winnt", 4096, 2, 64, true }
        };

        public string read_volume_id (string path) {
            try {
                var file = File.new_for_path (path);
                var stream = file.read ();
                stream.seek (16 * 2048, SeekType.SET);
                var pvd = new uint8[2048];
                size_t got;
                stream.read_all (pvd, out got);
                stream.close ();
                if (got < 72) return "";
                if (pvd[0] != 1 || pvd[1] != 'C' || pvd[2] != 'D' || pvd[3] != '0' || pvd[4] != '0' || pvd[5] != '1') return "";
                var sb = new StringBuilder ();
                for (int i = 40; i < 72; i++) sb.append_c ((char) pvd[i]);
                string v = sb.str.strip ();
                return v.validate () ? v : "";
            } catch (Error e) {
                return "";
            }
        }

        public bool looks_like_disk_image (string path) {
            string lower = path.down ();
            foreach (string ext in new string[] { ".qcow2", ".qcow", ".img", ".raw", ".vmdk", ".vdi", ".vhd", ".vhdx" }) {
                if (lower.has_suffix (ext)) return true;
            }
            try {
                var stream = File.new_for_path (path).read ();
                var head = new uint8[4];
                size_t got;
                stream.read_all (head, out got);
                stream.close ();
                if (got == 4 && head[0] == 'Q' && head[1] == 'F' && head[2] == 'I' && head[3] == 0xfb) return true;
            } catch (Error e) {
            }
            return false;
        }

        public string? version_in (string text) {
            try {
                var re = new Regex ("(?:^|[^0-9A-Za-z])([0-9]+(?:\\.[0-9]+)*)(?:[^0-9]|$)");
                MatchInfo mi;
                if (re.match (text, 0, out mi)) return mi.fetch (1);
            } catch (Error e) {
            }
            return null;
        }

        private bool contains_word (string haystack, string key) {
            int at = 0;
            while ((at = haystack.index_of (key, at)) >= 0) {
                bool left = at == 0 || !haystack[at - 1].isalpha ();
                int end = at + key.length;
                bool right = end >= haystack.length || !haystack[end].isalpha ();
                if (left && right) return true;
                at = end;
            }
            return false;
        }

        public bool hint_for (string text, out string distro, out string name, out string family, out int memory, out int cpus, out int disk, out bool efi) {
            string lower = text.down ();
            foreach (var h in HINTS) {
                if (contains_word (lower, h.key) || (h.key.length > 5 && lower.contains (h.key))) {
                    distro = h.distro;
                    name = h.name;
                    family = h.family;
                    memory = h.memory;
                    cpus = h.cpus;
                    disk = h.disk;
                    efi = h.efi;
                    return true;
                }
            }
            distro = name = family = "";
            memory = cpus = disk = 0;
            efi = false;
            return false;
        }

        private int round_memory (int64 mib) {
            if (mib <= 512) return 512;
            return (int) (((mib + 255) / 256) * 256);
        }

        public Detection detect (string path, OsDatabase? db, string arch, HostLimits limits) {
            var d = new Detection ();
            d.is_disk_image = looks_like_disk_image (path);
            if (!d.is_disk_image) d.volume_id = read_volume_id (path);
            string base_name = Path.get_basename (path);
            int dot = base_name.last_index_of_char ('.');
            if (dot > 0) base_name = base_name.substring (0, dot);
            OsInfo? os = null;
            if (db != null && d.volume_id != "") {
                os = db.match_volume (d.volume_id, arch);
                if (os != null) d.source = DetectionSource.OSINFO_MEDIA;
            }
            string distro, hname, family;
            int memory, cpus, disk;
            bool efi;
            bool hinted = hint_for (d.volume_id + " " + base_name, out distro, out hname, out family, out memory, out cpus, out disk, out efi);
            string? version = version_in (d.volume_id != "" ? d.volume_id : base_name);
            if (version == null && d.volume_id != "") version = version_in (base_name);
            if (os == null && hinted && db != null) {
                if (version != null) {
                    os = db.latest_of_distro (distro, version);
                    if (os == null && version.contains (".")) {
                        string[] parts = version.split (".");
                        os = db.latest_of_distro (distro, parts[0] + "." + parts[1]);
                    }
                }
                if (os != null) {
                    d.source = DetectionSource.OSINFO_MEDIA;
                } else {
                    os = db.latest_of_distro (distro);
                    if (os != null) d.source = DetectionSource.OSINFO_DISTRO;
                }
            }
            if (os != null) {
                d.os_id = os.id;
                d.family = os.family != "" ? os.family : family;
                if (d.source == DetectionSource.OSINFO_DISTRO) {
                    d.os_name = version != null ? "%s %s".printf (hname, version) : hname;
                } else {
                    d.os_name = os.name;
                }
                int64 ram = db.resolved_ram (os);
                int64 storage = db.resolved_storage (os);
                int ncpu = db.resolved_cpus (os);
                d.memory_mib = ram > 0 ? round_memory (ram / (1024 * 1024)) : (hinted ? memory : 2048);
                d.disk_gib = storage > 0 ? (int) int64.max (storage / (1024 * 1024 * 1024), 4) : (hinted ? disk : 20);
                d.cpus = ncpu > 0 ? ncpu : (hinted ? cpus : 2);
                d.prefer_efi = os.efi || efi;
                d.needs_efi = os.bios_unsupported;
                if (d.family.has_prefix ("win")) d.family = "winnt";
            } else if (hinted) {
                d.source = DetectionSource.HEURISTIC;
                d.os_id = distro;
                d.os_name = version != null && family != "winnt" ? "%s %s".printf (hname, version) : hname;
                d.family = family;
                d.memory_mib = memory;
                d.cpus = cpus;
                d.disk_gib = disk;
                d.prefer_efi = efi;
            } else {
                d.source = DetectionSource.NONE;
                d.os_name = "";
            }
            if (d.family == "linux" && d.cpus < 2 && limits.cpus >= 4) d.cpus = 2;
            d.memory_mib = (int) int64.min (d.memory_mib, int64.max (512, limits.memory_mib / 2));
            d.cpus = int.min (d.cpus, int.max (1, limits.cpus));
            return d;
        }
    }
}

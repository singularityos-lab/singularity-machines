namespace Singularity.Apps.Machines {

    public class OsMedia : Object {
        public string arch { get; set; default = ""; }
        public string volume_id { get; set; default = ""; }
    }

    public class OsInfo : Object {
        public string id { get; set; default = ""; }
        public string short_id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string version { get; set; default = ""; }
        public string vendor { get; set; default = ""; }
        public string family { get; set; default = ""; }
        public string distro { get; set; default = ""; }
        public string derives_from { get; set; default = ""; }
        public int64 minimum_ram { get; set; }
        public int64 recommended_ram { get; set; }
        public int64 recommended_storage { get; set; }
        public int recommended_cpus { get; set; }
        public bool efi { get; set; }
        public bool bios_unsupported { get; set; }
        public Gee.ArrayList<OsMedia> media = new Gee.ArrayList<OsMedia> ();
    }

    public class OsDatabase : Object {
        public Gee.HashMap<string, OsInfo> by_id = new Gee.HashMap<string, OsInfo> ();
        public Gee.ArrayList<OsInfo> entries = new Gee.ArrayList<OsInfo> ();
        public int files_read { get; private set; }

        private OsInfo? current;
        private OsMedia? current_media;
        private string[] stack = {};
        private bool localized;
        private string resources_arch = "";
        private string resources_kind = "";
        private StringBuilder text = new StringBuilder ();

        public void load_dirs (string[] dirs) {
            foreach (string dir in dirs) {
                string os_dir = Path.build_filename (dir, "os");
                if (FileUtils.test (os_dir, FileTest.IS_DIR)) walk (os_dir, 0);
            }
        }

        private void walk (string dir, int depth) {
            if (depth > 4) return;
            try {
                var d = Dir.open (dir);
                string? name;
                var names = new Gee.ArrayList<string> ();
                while ((name = d.read_name ()) != null) names.add (name);
                names.sort ((a, b) => strcmp (a, b));
                foreach (string n in names) {
                    string path = Path.build_filename (dir, n);
                    if (FileUtils.test (path, FileTest.IS_DIR)) {
                        walk (path, depth + 1);
                    } else if (n.has_suffix (".xml")) {
                        string contents;
                        FileUtils.get_contents (path, out contents);
                        try {
                            load_xml (contents);
                            files_read++;
                        } catch (Error e) {
                            warning ("machines: %s: %s", path, e.message);
                        }
                    }
                }
            } catch (Error e) {
            }
        }

        private string parent () {
            return stack.length >= 2 ? stack[stack.length - 2] : "";
        }

        private bool inside (string element) {
            foreach (string s in stack) {
                if (s == element) return true;
            }
            return false;
        }

        public void load_xml (string xml) throws MarkupError {
            var parser = MarkupParser ();
            parser.start_element = on_start;
            parser.end_element = on_end;
            parser.text = on_text;
            var ctx = new MarkupParseContext (parser, (MarkupParseFlags) 0, this, null);
            stack = {};
            current = null;
            current_media = null;
            ctx.parse (xml, -1);
            ctx.end_parse ();
        }

        private void on_start (MarkupParseContext ctx, string element, string[] names, string[] values) throws MarkupError {
            stack += element;
            text.truncate ();
            localized = false;
            for (int i = 0; i < names.length; i++) {
                if (names[i] == "xml:lang" || names[i] == "lang") localized = true;
            }
            if (element == "os" && stack.length == 2) {
                current = new OsInfo ();
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "id") current.id = values[i];
                }
                return;
            }
            if (current == null) return;
            if (element == "derives-from" && parent () == "os") {
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "id") current.derives_from = values[i];
                }
            } else if (element == "resources" && parent () == "os") {
                resources_arch = "all";
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "arch") resources_arch = values[i];
                }
            } else if ((element == "minimum" || element == "recommended") && parent () == "resources") {
                resources_kind = element;
            } else if (element == "media" && parent () == "os") {
                current_media = new OsMedia ();
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "arch") current_media.arch = values[i];
                }
            } else if (element == "firmware" && parent () == "os") {
                string arch = "", type = "";
                bool supported = true;
                for (int i = 0; i < names.length; i++) {
                    if (names[i] == "arch") arch = values[i];
                    else if (names[i] == "type") type = values[i];
                    else if (names[i] == "supported") supported = values[i] != "false";
                }
                if (arch == "x86_64" || arch == "") {
                    if (type == "efi" && supported) current.efi = true;
                    if (type == "bios" && !supported) current.bios_unsupported = true;
                }
            }
        }

        private void on_text (MarkupParseContext ctx, string t, size_t len) throws MarkupError {
            text.append_len (t, (ssize_t) len);
        }

        private void on_end (MarkupParseContext ctx, string element) throws MarkupError {
            string value = text.str.strip ();
            text.truncate ();
            string par = parent ();
            if (current != null) {
                if (element == "os" && stack.length == 2) {
                    if (current.id != "") {
                        by_id[current.id] = current;
                        entries.add (current);
                    }
                    current = null;
                } else if (element == "media" && par == "os") {
                    if (current_media != null) current.media.add (current_media);
                    current_media = null;
                } else if (par == "os" && !localized) {
                    switch (element) {
                        case "short-id":
                            if (current.short_id == "") current.short_id = value;
                            break;
                        case "name":
                            current.name = value;
                            break;
                        case "version":
                            current.version = value;
                            break;
                        case "vendor":
                            current.vendor = value;
                            break;
                        case "family":
                            current.family = value;
                            break;
                        case "distro":
                            current.distro = value;
                            break;
                    }
                } else if (element == "volume-id" && par == "iso" && current_media != null) {
                    current_media.volume_id = value;
                } else if ((par == "minimum" || par == "recommended") && inside ("resources")) {
                    if (resources_arch == "all" || resources_arch == "x86_64") {
                        int64 n = int64.parse (value);
                        if (par == "recommended") {
                            if (element == "ram") current.recommended_ram = n;
                            else if (element == "storage") current.recommended_storage = n;
                            else if (element == "n-cpus") current.recommended_cpus = (int) n;
                        } else if (element == "ram") {
                            current.minimum_ram = n;
                        }
                    }
                }
            }
            if (stack.length > 0) stack = stack[0:stack.length - 1];
        }

        public OsInfo? find (string id) {
            return by_id.has_key (id) ? by_id[id] : null;
        }

        public OsInfo? match_volume (string volume_id, string arch) {
            if (volume_id == "") return null;
            OsInfo? best = null;
            foreach (var os in entries) {
                foreach (var m in os.media) {
                    if (m.volume_id == "" || (m.arch != "" && m.arch != arch && m.arch != "all")) continue;
                    try {
                        var re = new Regex (m.volume_id);
                        if (re.match (volume_id)) {
                            if (best == null || compare_versions (os.version, best.version) > 0) best = os;
                        }
                    } catch (Error e) {
                    }
                }
            }
            return best;
        }

        public OsInfo? latest_of_distro (string distro, string? version_prefix = null) {
            OsInfo? best = null;
            foreach (var os in entries) {
                if (os.distro != distro) continue;
                if (version_prefix != null && version_prefix != "" && os.version != version_prefix && !os.version.has_prefix (version_prefix + ".")) continue;
                if (!numeric_version (os.version)) continue;
                if (best == null || compare_versions (os.version, best.version) > 0) best = os;
            }
            return best;
        }

        private static bool numeric_version (string v) {
            if (v == "") return false;
            for (int i = 0; i < v.length; i++) {
                char c = v[i];
                if (!c.isdigit () && c != '.') return false;
            }
            return true;
        }

        public static int compare_versions (string a, string b) {
            string[] pa = a.split (".");
            string[] pb = b.split (".");
            for (int i = 0; i < int.max (pa.length, pb.length); i++) {
                int x = i < pa.length ? int.parse (pa[i]) : 0;
                int y = i < pb.length ? int.parse (pb[i]) : 0;
                if (x != y) return x < y ? -1 : 1;
            }
            return 0;
        }

        public int64 resolved_ram (OsInfo os) {
            var o = os;
            for (int i = 0; i < 8 && o != null; i++) {
                if (o.recommended_ram > 0) return o.recommended_ram;
                o = o.derives_from != "" ? find (o.derives_from) : null;
            }
            return 0;
        }

        public int64 resolved_storage (OsInfo os) {
            var o = os;
            for (int i = 0; i < 8 && o != null; i++) {
                if (o.recommended_storage > 0) return o.recommended_storage;
                o = o.derives_from != "" ? find (o.derives_from) : null;
            }
            return 0;
        }

        public int resolved_cpus (OsInfo os) {
            var o = os;
            for (int i = 0; i < 8 && o != null; i++) {
                if (o.recommended_cpus > 0) return o.recommended_cpus;
                o = o.derives_from != "" ? find (o.derives_from) : null;
            }
            return 0;
        }
    }
}

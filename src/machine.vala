namespace Singularity.Apps.Machines {

    public class SnapshotInfo : Object {
        public string tag { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public int64 created { get; set; }
        public bool with_state { get; set; }
    }

    public class Machine : Object {
        public string id { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string os_id { get; set; default = ""; }
        public string os_name { get; set; default = ""; }
        public string family { get; set; default = "linux"; }
        public string backend { get; set; default = "qemu"; }
        public int memory_mib { get; set; default = 2048; }
        public int cpus { get; set; default = 2; }
        public int disk_gib { get; set; default = 20; }
        public bool uefi { get; set; }
        public string firmware_code { get; set; default = ""; }
        public string firmware_format { get; set; default = "raw"; }
        public string install_media { get; set; default = ""; }
        public string source_image { get; set; default = ""; }
        public string shared_folder { get; set; default = ""; }
        public bool resize_guest { get; set; default = true; }
        public int64 created { get; set; }
        public int64 last_used { get; set; }
        public string dir { get; set; default = ""; }
        public Gee.ArrayList<SnapshotInfo> snapshots = new Gee.ArrayList<SnapshotInfo> ();

        public signal void changed ();

        public string disk_path () {
            return Path.build_filename (dir, "disk.qcow2");
        }

        public string vars_path () {
            return Path.build_filename (dir, "efivars.qcow2");
        }

        public string screenshot_path () {
            return Path.build_filename (dir, "screenshot.png");
        }

        public string config_path () {
            return Path.build_filename (dir, "machine.json");
        }

        public string title () {
            return name != "" ? name : (os_name != "" ? os_name : _("Machine"));
        }

        public static string new_id () {
            var sb = new StringBuilder ();
            for (int i = 0; i < 8; i++) sb.append_printf ("%x", Random.int_range (0, 16));
            return sb.str;
        }

        public SnapshotInfo? find_snapshot (string tag) {
            foreach (var s in snapshots) {
                if (s.tag == tag) return s;
            }
            return null;
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("version").add_int_value (1);
            b.set_member_name ("id").add_string_value (id);
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("os-id").add_string_value (os_id);
            b.set_member_name ("os-name").add_string_value (os_name);
            b.set_member_name ("family").add_string_value (family);
            b.set_member_name ("backend").add_string_value (backend);
            b.set_member_name ("memory-mib").add_int_value (memory_mib);
            b.set_member_name ("cpus").add_int_value (cpus);
            b.set_member_name ("disk-gib").add_int_value (disk_gib);
            b.set_member_name ("uefi").add_boolean_value (uefi);
            b.set_member_name ("firmware-code").add_string_value (firmware_code);
            b.set_member_name ("firmware-format").add_string_value (firmware_format);
            b.set_member_name ("install-media").add_string_value (install_media);
            b.set_member_name ("source-image").add_string_value (source_image);
            b.set_member_name ("shared-folder").add_string_value (shared_folder);
            b.set_member_name ("resize-guest").add_boolean_value (resize_guest);
            b.set_member_name ("created").add_int_value (created);
            b.set_member_name ("last-used").add_int_value (last_used);
            b.set_member_name ("snapshots");
            b.begin_array ();
            foreach (var s in snapshots) {
                b.begin_object ();
                b.set_member_name ("tag").add_string_value (s.tag);
                b.set_member_name ("name").add_string_value (s.name);
                b.set_member_name ("created").add_int_value (s.created);
                b.set_member_name ("with-state").add_boolean_value (s.with_state);
                b.end_object ();
            }
            b.end_array ();
            b.end_object ();
            return b.get_root ();
        }

        public static Machine? from_json (Json.Node node) {
            if (node.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = node.get_object ();
            var m = new Machine ();
            m.id = o.get_string_member_with_default ("id", "");
            if (m.id == "") return null;
            m.name = o.get_string_member_with_default ("name", "");
            m.os_id = o.get_string_member_with_default ("os-id", "");
            m.os_name = o.get_string_member_with_default ("os-name", "");
            m.family = o.get_string_member_with_default ("family", "linux");
            m.backend = o.get_string_member_with_default ("backend", "qemu");
            m.memory_mib = (int) o.get_int_member_with_default ("memory-mib", 2048).clamp (128, 1 << 20);
            m.cpus = (int) o.get_int_member_with_default ("cpus", 2).clamp (1, 256);
            m.disk_gib = (int) o.get_int_member_with_default ("disk-gib", 20).clamp (1, 1 << 16);
            m.uefi = o.get_boolean_member_with_default ("uefi", false);
            m.firmware_code = o.get_string_member_with_default ("firmware-code", "");
            m.firmware_format = o.get_string_member_with_default ("firmware-format", "raw");
            m.install_media = o.get_string_member_with_default ("install-media", "");
            m.source_image = o.get_string_member_with_default ("source-image", "");
            m.shared_folder = o.get_string_member_with_default ("shared-folder", "");
            m.resize_guest = o.get_boolean_member_with_default ("resize-guest", true);
            m.created = o.get_int_member_with_default ("created", 0);
            m.last_used = o.get_int_member_with_default ("last-used", 0);
            if (o.has_member ("snapshots")) {
                var arr = o.get_array_member ("snapshots");
                for (uint i = 0; i < arr.get_length (); i++) {
                    var so = arr.get_object_element (i);
                    if (so == null) continue;
                    var s = new SnapshotInfo ();
                    s.tag = so.get_string_member_with_default ("tag", "");
                    s.name = so.get_string_member_with_default ("name", "");
                    s.created = so.get_int_member_with_default ("created", 0);
                    s.with_state = so.get_boolean_member_with_default ("with-state", false);
                    if (s.tag != "") m.snapshots.add (s);
                }
            }
            return m;
        }

        public string serialize () {
            var gen = new Json.Generator ();
            gen.pretty = true;
            gen.set_root (to_json ());
            return gen.to_data (null);
        }

        public static Machine? parse (string text) {
            try {
                var p = new Json.Parser ();
                p.load_from_data (text);
                return from_json (p.get_root ());
            } catch (Error e) {
                return null;
            }
        }
    }

    public class MachineStore : Object {
        public string root { get; construct; }
        public Gee.ArrayList<Machine> items = new Gee.ArrayList<Machine> ();

        public signal void changed ();

        public MachineStore (string root) {
            Object (root: root);
        }

        public void load () {
            items.clear ();
            try {
                var d = Dir.open (root);
                string? name;
                while ((name = d.read_name ()) != null) {
                    string dir = Path.build_filename (root, name);
                    string cfg = Path.build_filename (dir, "machine.json");
                    if (!FileUtils.test (cfg, FileTest.IS_REGULAR)) continue;
                    string text;
                    FileUtils.get_contents (cfg, out text);
                    var m = Machine.parse (text);
                    if (m == null || m.id != name) continue;
                    m.dir = dir;
                    items.add (m);
                }
            } catch (Error e) {
            }
            sort ();
            changed ();
        }

        private void sort () {
            items.sort ((a, b) => {
                if (a.last_used != b.last_used) return a.last_used > b.last_used ? -1 : 1;
                return strcmp (a.title ().down (), b.title ().down ());
            });
        }

        public Machine? find (string id) {
            foreach (var m in items) {
                if (m.id == id) return m;
            }
            return null;
        }

        public string allocate_dir (Machine m) throws Error {
            DirUtils.create_with_parents (root, 0700);
            for (int i = 0; i < 16; i++) {
                if (m.id == "" || FileUtils.test (Path.build_filename (root, m.id), FileTest.EXISTS)) m.id = Machine.new_id ();
                else break;
            }
            string dir = Path.build_filename (root, m.id);
            if (DirUtils.create (dir, 0700) != 0) throw new IOError.FAILED (_("The folder for the machine could not be created."));
            m.dir = dir;
            return dir;
        }

        public void save (Machine m) throws Error {
            if (m.dir == "") allocate_dir (m);
            FileUtils.set_contents (m.config_path (), m.serialize ());
            if (!items.contains (m)) items.add (m);
            sort ();
            m.changed ();
            changed ();
        }

        public void put (Machine m) {
            try {
                save (m);
            } catch (Error e) {
                warning ("machines: %s", e.message);
            }
        }

        public void remove (Machine m) {
            items.remove (m);
            if (m.dir != "" && m.dir.has_prefix (root + "/")) {
                foreach (string f in new string[] { "machine.json", "disk.qcow2", "efivars.qcow2", "screenshot.png", "import.log" }) {
                    FileUtils.unlink (Path.build_filename (m.dir, f));
                }
                DirUtils.remove (m.dir);
            }
            changed ();
        }
    }
}

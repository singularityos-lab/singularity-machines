namespace Singularity.Apps.Machines {

    internal class MachinesIntents : Object {

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key).strip () : "";
        }

        private static string state_name (MachineState s) {
            switch (s) {
                case MachineState.PREPARING: return "preparing";
                case MachineState.STARTING: return "starting";
                case MachineState.RUNNING: return "running";
                case MachineState.PAUSED: return "paused";
                case MachineState.STOPPING: return "shutting down";
                default: return "off";
            }
        }

        private static Machine find (MachinesApp app, string wanted) throws Error {
            var items = app.manager.store.items;
            if (wanted == "") {
                if (items.size == 1) return items[0];
                throw new IOError.INVALID_ARGUMENT ("give the machine id or name from machines_list");
            }
            foreach (var m in items) if (m.id == wanted) return m;
            string w = wanted.casefold ();
            foreach (var m in items) if (m.title ().casefold () == w) return m;
            Machine? hit = null;
            foreach (var m in items) {
                if (!m.title ().casefold ().contains (w)) continue;
                if (hit != null) throw new IOError.INVALID_ARGUMENT ("%s matches more than one machine; use the id", wanted);
                hit = m;
            }
            if (hit != null) return hit;
            throw new IOError.NOT_FOUND ("no machine %s; see machines_list", wanted);
        }

        private static string path_arg (Json.Object args, string key) throws Error {
            string p = text (args, key);
            if (p == "") throw new IOError.INVALID_ARGUMENT ("give the %s", key);
            if (p.has_prefix ("~/")) return Path.build_filename (Environment.get_home_dir (), p.substring (2));
            if (!Path.is_absolute (p)) return Path.build_filename (Environment.get_home_dir (), p);
            return p;
        }

        private static void entry (Json.Builder b, MachinesApp app, Machine m) {
            b.begin_object ();
            b.set_member_name ("id").add_string_value (m.id);
            b.set_member_name ("name").add_string_value (m.title ());
            if (m.os_name != "") b.set_member_name ("system").add_string_value (m.os_name);
            b.set_member_name ("state").add_string_value (state_name (app.manager.state_of (m)));
            b.set_member_name ("memory_gib").add_double_value (m.memory_mib / 1024.0);
            b.set_member_name ("processors").add_int_value (m.cpus);
            b.set_member_name ("disk_gib").add_int_value (m.disk_gib);
            b.set_member_name ("uefi").add_boolean_value (m.uefi);
            if (m.install_media != "") b.set_member_name ("install_media").add_string_value (m.install_media);
            if (m.snapshots.size > 0) {
                b.set_member_name ("snapshots").begin_array ();
                foreach (var s in m.snapshots) {
                    b.begin_object ();
                    b.set_member_name ("tag").add_string_value (s.tag);
                    b.set_member_name ("name").add_string_value (s.name);
                    b.set_member_name ("taken").add_string_value (new DateTime.from_unix_local (s.created).format_iso8601 ());
                    b.end_object ();
                }
                b.end_array ();
            }
            b.end_object ();
        }

        private static Json.Node one (MachinesApp app, Machine m, string? undo) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("machine");
            entry (b, app, m);
            if (undo != null) b.set_member_name ("undo").add_string_value (undo);
            b.end_object ();
            return b.get_root ();
        }

        private static async void settle (MachineController c, bool alive, int seconds) {
            for (int i = 0; i < seconds * 10; i++) {
                if (c.state.alive () == alive && c.state != MachineState.STARTING && c.state != MachineState.PREPARING) return;
                Timeout.add (100, settle.callback);
                yield;
            }
        }

        private static async void dispatch (MachinesApp app, string name, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                reply (yield work (app, name, args), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async Json.Node work (MachinesApp app, string name, Json.Object args) throws Error {
            var manager = app.manager;
            switch (name) {
                case "create": {
                    string path = path_arg (args, "image");
                    if (!FileUtils.test (path, FileTest.EXISTS)) throw new IOError.NOT_FOUND ("%s does not exist", path);
                    if (!manager.backend.available ()) throw new IOError.NOT_SUPPORTED ("%s", manager.backend.unavailable_reason ());
                    yield manager.load_osdb ();
                    var d = Detector.detect (path, manager.osdb, manager.host.arch, manager.limits);
                    var m = new Machine ();
                    string base_name = text (args, "name") != "" ? text (args, "name") : (d.os_name != "" ? d.os_name : Path.get_basename (path));
                    foreach (var x in manager.store.items) if (x.name == base_name) throw new IOError.EXISTS ("a machine named %s exists", base_name);
                    m.name = base_name;
                    m.os_id = d.os_id;
                    m.os_name = d.os_name;
                    m.family = d.family;
                    m.backend = manager.backend.id;
                    double gib = args.has_member ("memory_gib") ? args.get_double_member ("memory_gib") : d.memory_mib / 1024.0;
                    m.memory_mib = (int) Math.round (double.min (gib, manager.limits.memory_mib / 1024.0) * 1024);
                    if (m.memory_mib < 256) throw new IOError.INVALID_ARGUMENT ("give at least 0.25 GiB of memory");
                    m.cpus = args.has_member ("processors") ? (int) args.get_int_member ("processors").clamp (1, manager.limits.cpus) : d.cpus;
                    m.disk_gib = args.has_member ("disk_gib") ? (int) args.get_int_member ("disk_gib").clamp (1, 4096) : d.disk_gib;
                    m.uefi = (d.prefer_efi || d.needs_efi) && manager.host.find_firmware () != null;
                    if (d.is_disk_image) m.source_image = path;
                    else m.install_media = path;
                    m.created = new DateTime.now_utc ().to_unix ();
                    m.last_used = m.created;
                    manager.store.allocate_dir (m);
                    manager.store.save (m);
                    yield manager.backend_for (m).prepare (m, null);
                    manager.store.load ();
                    var saved = manager.store.find (m.id);
                    if (saved == null) throw new IOError.FAILED ("the machine was not saved");
                    var w = app.agent_window ();
                    w.show_page ("grid");
                    w.present ();
                    return one (app, saved, "machines_delete with machine " + m.id);
                }
                case "power": {
                    var m = find (app, text (args, "machine"));
                    var c = manager.controller (m);
                    string action = text (args, "action");
                    var before = c.state;
                    switch (action) {
                        case "start":
                            if (c.state.alive ()) throw new IOError.EXISTS ("%s is already %s", m.title (), state_name (c.state));
                            var w = app.agent_window ();
                            w.open_machine (m);
                            w.present ();
                            if (!c.state.alive () && c.state != MachineState.STARTING) yield c.start (null);
                            yield settle (c, true, 30);
                            if (!c.state.alive ()) throw new IOError.FAILED ("%s did not start: %s", m.title (), c.status_detail);
                            break;
                        case "shutdown":
                            if (!c.state.alive ()) throw new IOError.NOT_FOUND ("%s is off", m.title ());
                            yield c.shutdown ();
                            break;
                        case "pause":
                            if (c.state != MachineState.RUNNING) throw new IOError.NOT_FOUND ("%s is not running", m.title ());
                            yield c.pause ();
                            if (c.state != MachineState.PAUSED) throw new IOError.FAILED ("%s did not pause", m.title ());
                            break;
                        case "resume":
                            if (c.state != MachineState.PAUSED) throw new IOError.NOT_FOUND ("%s is not paused", m.title ());
                            yield c.resume ();
                            if (c.state != MachineState.RUNNING) throw new IOError.FAILED ("%s did not resume", m.title ());
                            break;
                        default:
                            throw new IOError.INVALID_ARGUMENT ("action is start, shutdown, pause or resume");
                    }
                    string undo = action == "start" ? "machines_power with action shutdown" : (action == "pause" ? "machines_power with action resume" : (action == "resume" ? "machines_power with action pause" : "machines_power with action start"));
                    var root = one (app, m, undo + " and machine " + m.id);
                    root.get_object ().set_string_member ("was", state_name (before));
                    if (action == "shutdown") root.get_object ().set_string_member ("note", "the system inside was asked to shut down; it turns off when it is ready");
                    return root;
                }
                case "force": {
                    var m = find (app, text (args, "machine"));
                    var c = manager.controller (m);
                    string action = text (args, "action");
                    if (!c.state.alive ()) throw new IOError.NOT_FOUND ("%s is off", m.title ());
                    if (action == "off") {
                        yield c.force_off ();
                        yield settle (c, false, 10);
                        if (c.state.alive ()) throw new IOError.FAILED ("%s is still on", m.title ());
                    } else if (action == "restart") {
                        yield c.reset ();
                    } else {
                        throw new IOError.INVALID_ARGUMENT ("action is off or restart");
                    }
                    return one (app, m, null);
                }
                case "snapshot": {
                    var m = find (app, text (args, "machine"));
                    var c = manager.controller (m);
                    var s = new SnapshotInfo ();
                    s.created = new DateTime.now_utc ().to_unix ();
                    s.tag = "snap-%s".printf (new DateTime.now_utc ().format ("%Y%m%d-%H%M%S"));
                    if (m.find_snapshot (s.tag) != null) s.tag += "-%d".printf (m.snapshots.size);
                    s.name = text (args, "name") != "" ? text (args, "name") : new DateTime.now_local ().format ("Snapshot of %e %B, %H:%M").replace ("  ", " ");
                    s.with_state = c.state.alive ();
                    yield c.take_snapshot (s.tag);
                    m.snapshots.add (s);
                    manager.store.put (m);
                    var root = one (app, m, "machines_delete_snapshot with machine %s and snapshot %s".printf (m.id, s.tag));
                    root.get_object ().set_string_member ("taken", s.tag);
                    return root;
                }
                case "revert":
                case "delete_snapshot": {
                    var m = find (app, text (args, "machine"));
                    var c = manager.controller (m);
                    string tag = text (args, "snapshot");
                    var s = m.find_snapshot (tag);
                    if (s == null) foreach (var x in m.snapshots) if (x.name == tag) s = x;
                    if (s == null) throw new IOError.NOT_FOUND ("%s has no snapshot %s", m.title (), tag);
                    if (name == "revert") {
                        yield c.revert_snapshot (s.tag);
                        if (c.state.alive ()) app.agent_window ().open_machine (m);
                    } else {
                        yield c.delete_snapshot (s.tag);
                        m.snapshots.remove (s);
                        manager.store.put (m);
                    }
                    return one (app, m, null);
                }
                case "screenshot": {
                    var m = find (app, text (args, "machine"));
                    var c = manager.existing (m);
                    if (c == null || c.state != MachineState.RUNNING) throw new IOError.NOT_FOUND ("%s is not running", m.title ());
                    string path = m.screenshot_path ();
                    if (!(yield c.screendump (path))) throw new IOError.FAILED ("the screen of %s could not be captured", m.title ());
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("machine").add_string_value (m.title ());
                    b.set_member_name ("image").add_string_value (path);
                    b.set_member_name ("bytes").add_int_value (File.new_for_path (path).query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size ());
                    b.end_object ();
                    return b.get_root ();
                }
                default: {
                    var m = find (app, text (args, "machine"));
                    string title = m.title ();
                    string dir = m.dir;
                    yield app.agent_window ().delete_machine (m);
                    manager.store.load ();
                    if (manager.store.find (m.id) != null) throw new IOError.FAILED ("%s is still listed", title);
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("deleted").add_string_value (title);
                    b.set_member_name ("files_removed").add_boolean_value (dir == "" || !FileUtils.test (dir, FileTest.EXISTS));
                    b.end_object ();
                    return b.get_root ();
                }
            }
        }

        internal static void install (MachinesApp app) {
            var agent = app.agent;
            agent.add_intent ("machines_list", "The virtual machines in Machines: system, state, memory, processors, disk and snapshots.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("machines").begin_array ();
                    foreach (var m in app.manager.store.items) entry (b, app, m);
                    b.end_array ();
                    b.set_member_name ("backend").add_string_value (app.manager.backend.label);
                    b.set_member_name ("hardware_acceleration").add_boolean_value (app.manager.host.kvm_available ());
                    b.end_object ();
                    return b.get_root ();
                });
            agent.add_async_intent ("machines_create", "Create a virtual machine from an installation image (.iso) or a disk image. The system is recognized and sensible memory, processors and disk are chosen unless given. It is created off.",
                "{\"type\":\"object\",\"properties\":{\"image\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"memory_gib\":{\"type\":\"number\"},\"processors\":{\"type\":\"integer\"},\"disk_gib\":{\"type\":\"integer\"}},\"required\":[\"image\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "create", args, (owned) reply);
                });
            agent.add_async_intent ("machines_power", "Start a machine and show it, ask it to shut down, pause it or resume it.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"start\",\"shutdown\",\"pause\",\"resume\"]}},\"required\":[\"action\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "power", args, (owned) reply);
                });
            agent.add_async_intent ("machines_force", "Force a machine off or restart it at once, like pulling the plug. Unsaved work inside it is lost.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"off\",\"restart\"]}},\"required\":[\"action\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    dispatch.begin (app, "force", args, (owned) reply);
                });
            agent.add_async_intent ("machines_snapshot", "Take a snapshot of a machine, with its running state when it is on.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "snapshot", args, (owned) reply);
                });
            agent.add_async_intent ("machines_revert", "Bring a machine back to a snapshot. Changes made since then are lost.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"},\"snapshot\":{\"type\":\"string\"}},\"required\":[\"snapshot\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    dispatch.begin (app, "revert", args, (owned) reply);
                });
            agent.add_async_intent ("machines_delete_snapshot", "Delete a snapshot of a machine.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"},\"snapshot\":{\"type\":\"string\"}},\"required\":[\"snapshot\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    dispatch.begin (app, "delete_snapshot", args, (owned) reply);
                });
            agent.add_async_intent ("machines_screenshot", "Capture the screen of a running machine to a PNG file, to look at what it shows.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    dispatch.begin (app, "screenshot", args, (owned) reply);
                });
            agent.add_async_intent ("machines_delete", "Delete a machine with its disk and snapshots. A running machine is forced off first.",
                "{\"type\":\"object\",\"properties\":{\"machine\":{\"type\":\"string\"}},\"required\":[\"machine\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    dispatch.begin (app, "delete", args, (owned) reply);
                });
        }
    }
}

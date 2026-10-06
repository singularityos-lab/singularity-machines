namespace Singularity.Apps.Machines {

    public class MachineManager : Object {
        public HostConfig host { get; construct; }
        public MachineStore store { get; private set; }
        public MachineBackend backend { get; private set; }
        public HostLimits limits { get; private set; }
        public OsDatabase? osdb { get; private set; }
        public bool osdb_ready { get; private set; }
        private Gee.HashMap<string, MachineController> controllers = new Gee.HashMap<string, MachineController> ();
        private Gee.HashMap<string, MachineBackend> backends = new Gee.HashMap<string, MachineBackend> ();

        public signal void state_changed (Machine m);
        public signal void thumbnail_changed (Machine m);
        public signal void controller_failed (Machine m, string message);

        public MachineManager (HostConfig host) {
            Object (host: host);
            store = new MachineStore (host.storage_dir ());
            backend = Backends.choose (host);
            backends[backend.id] = backend;
            limits = HostLimits.read ();
        }

        public MachineBackend backend_for (Machine m) {
            if (!backends.has_key (m.backend)) backends[m.backend] = Backends.create (m.backend, host);
            return backends[m.backend];
        }

        public MachineController controller (Machine m) {
            if (controllers.has_key (m.id)) return controllers[m.id];
            var c = backend_for (m).controller (m);
            c.notify["state"].connect (() => state_changed (m));
            c.stopped.connect (() => state_changed (m));
            controllers[m.id] = c;
            return c;
        }

        public MachineController? existing (Machine m) {
            return controllers.has_key (m.id) ? controllers[m.id] : null;
        }

        public MachineState state_of (Machine m) {
            var c = existing (m);
            return c != null ? c.state : MachineState.OFF;
        }

        public async void reconnect_all () {
            foreach (var m in store.items) yield controller (m).reconnect ();
        }

        public async OsDatabase? load_osdb () {
            if (osdb_ready) return osdb;
            string[] dirs = host.effective_osinfo_dirs ();
            OsDatabase? result = null;
            SourceFunc resume = load_osdb.callback;
            new Thread<bool> ("osinfo", () => {
                var db = new OsDatabase ();
                db.load_dirs (dirs);
                result = db;
                Idle.add ((owned) resume);
                return true;
            });
            yield;
            osdb = result != null && result.entries.size > 0 ? result : null;
            osdb_ready = true;
            return osdb;
        }

        public async void refresh_thumbnail (Machine m) {
            var c = existing (m);
            if (c == null || c.state != MachineState.RUNNING) return;
            try {
                if (yield c.screendump (m.screenshot_path ())) thumbnail_changed (m);
            } catch (Error e) {
            }
        }

        public void forget (Machine m) {
            controllers.unset (m.id);
        }
    }
}

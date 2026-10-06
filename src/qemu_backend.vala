namespace Singularity.Apps.Machines {

    namespace Tool {
        public async string run (string[] argv, Cancellable? cancel = null) throws Error {
            var proc = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDIN_INHERIT);
            string? out_text, err_text;
            yield proc.communicate_utf8_async (null, cancel, out out_text, out err_text);
            if (!proc.get_if_exited () || proc.get_exit_status () != 0) {
                throw new IOError.FAILED (tidy (err_text ?? "", argv[0]));
            }
            return out_text ?? "";
        }

        public string tidy (string text, string program) {
            var sb = new StringBuilder ();
            string prefix = Path.get_basename (program) + ": ";
            foreach (string raw in text.split ("\n")) {
                string line = raw.strip ();
                if (line == "" || line.contains ("dbind") || line.contains ("accessibility bus")) continue;
                if (line.has_prefix (prefix)) line = line.substring (prefix.length);
                if (sb.len > 0) sb.append ("\n");
                sb.append (line);
            }
            return sb.len > 0 ? sb.str : _("The command %s failed.").printf (Path.get_basename (program));
        }

        public int read_pid (string path) {
            try {
                string s;
                FileUtils.get_contents (path, out s);
                return int.parse (s.strip ());
            } catch (Error e) {
                return 0;
            }
        }

        public bool owns_pid (int pid, string marker) {
            if (pid <= 0) return false;
            try {
                uint8[] data;
                FileUtils.get_data ("/proc/%d/cmdline".printf (pid), out data);
                for (int i = 0; i < data.length; i++) {
                    if (data[i] == 0) data[i] = ' ';
                }
                return ((string) data).contains (marker);
            } catch (Error e) {
                return false;
            }
        }

        public async void sleep (uint ms) {
            Timeout.add (ms, sleep.callback);
            yield;
        }
    }

    public class QemuBackend : MachineBackend {
        public QemuBackend (HostConfig host) {
            Object (host: host);
        }

        public override string id {
            get { return "qemu"; }
        }

        public override string label {
            get { return "QEMU"; }
        }

        public override bool available () {
            return host.qemu_binary () != null && host.qemu_img_binary () != null;
        }

        public override string unavailable_reason () {
            if (host.qemu_binary () == null) return _("QEMU is not installed. Install the package that provides %s.").printf (host.qemu != "" ? host.qemu : "qemu-system-" + host.arch);
            if (host.qemu_img_binary () == null) return _("The qemu-img tool is not installed.");
            return "";
        }

        public override async void prepare (Machine m, Cancellable? cancel) throws Error {
            string? img = host.qemu_img_binary ();
            if (img == null) throw new IOError.NOT_FOUND (unavailable_reason ());
            if (!FileUtils.test (m.disk_path (), FileTest.EXISTS)) {
                if (m.source_image != "") {
                    string partial = m.disk_path () + ".part";
                    FileUtils.unlink (partial);
                    try {
                        yield Tool.run (QemuCommand.import_disk_args (img, m.source_image, partial), cancel);
                    } catch (Error e) {
                        FileUtils.unlink (partial);
                        throw e;
                    }
                    FileUtils.rename (partial, m.disk_path ());
                } else {
                    yield Tool.run (QemuCommand.create_disk_args (img, m.disk_path (), m.disk_gib), cancel);
                }
            }
            if (m.uefi) yield ensure_vars (m);
        }

        public async Firmware ensure_vars (Machine m) throws Error {
            if (m.firmware_code != "" && FileUtils.test (m.firmware_code, FileTest.IS_REGULAR)) {
                var kept = new Firmware ();
                kept.code = m.firmware_code;
                kept.code_format = m.firmware_format;
                kept.vars = FileUtils.test (m.vars_path (), FileTest.EXISTS) ? m.vars_path () : "";
                kept.source = "machine";
                return kept;
            }
            var fw = host.find_firmware ();
            if (fw == null) throw new IOError.NOT_FOUND (_("No UEFI firmware was found. Install OVMF or set FirmwareCode in machines.conf."));
            if (fw.vars != "" && !FileUtils.test (m.vars_path (), FileTest.EXISTS)) {
                yield Tool.run (QemuCommand.vars_args (host.qemu_img_binary () ?? "qemu-img", fw, m.vars_path ()));
            }
            m.firmware_code = fw.code;
            m.firmware_format = fw.code_format;
            return fw;
        }

        public override MachineController controller (Machine m) {
            return new QemuController (m, this);
        }

        public override async void destroy (Machine m) throws Error {
        }
    }

    public class QemuController : MachineController {
        public QemuBackend backend { get; construct; }
        public RuntimePaths runtime { get; private set; }
        private QmpClient? qmp;
        private string marker;

        public QemuController (Machine m, QemuBackend backend) {
            Object (machine: m, backend: backend);
            runtime = RuntimePaths.for_machine (backend.host.runtime_root (), m.id);
            marker = "process=machines-" + m.id;
        }

        private void set_state_from (string status) {
            if (status == "paused" || status == "suspended" || status == "save-vm" || status == "restore-vm") state = MachineState.PAUSED;
            else if (status == "shutdown") state = MachineState.STOPPING;
            else state = MachineState.RUNNING;
        }

        private void clean_runtime () {
            foreach (string f in new string[] { runtime.qmp, runtime.vnc, runtime.pid, runtime.fs_socket, runtime.fs_pid, runtime.fs_socket + ".pid" }) FileUtils.unlink (f);
            DirUtils.remove (runtime.dir);
        }

        private async void attach_qmp (int attempts) throws Error {
            Error? last = null;
            for (int i = 0; i < attempts; i++) {
                var c = new QmpClient ();
                try {
                    yield c.open (runtime.qmp);
                    qmp = c;
                    c.event.connect (on_event);
                    c.disconnected.connect (() => {
                        if (qmp == c) lost.begin ();
                    });
                    var st = yield c.execute ("query-status");
                    if (st != null && st.get_node_type () == Json.NodeType.OBJECT) set_state_from (st.get_object ().get_string_member_with_default ("status", "running"));
                    else state = MachineState.RUNNING;
                    var kvm = yield c.execute ("query-kvm");
                    accelerated = kvm != null && kvm.get_object ().get_boolean_member_with_default ("enabled", false);
                    return;
                } catch (Error e) {
                    last = e;
                    yield Tool.sleep (150);
                }
            }
            throw last ?? new QmpError.CLOSED (_("The machine did not answer."));
        }

        private void on_event (string name, Json.Object? data) {
            switch (name) {
                case "STOP":
                    if (state != MachineState.STOPPING) state = MachineState.PAUSED;
                    break;
                case "RESUME":
                    state = MachineState.RUNNING;
                    break;
                case "SHUTDOWN":
                case "POWERDOWN":
                    state = MachineState.STOPPING;
                    break;
            }
        }

        private async void lost () {
            qmp = null;
            int pid = Tool.read_pid (runtime.pid);
            for (int i = 0; i < 30 && Tool.owns_pid (pid, marker); i++) yield Tool.sleep (100);
            if (Tool.owns_pid (pid, marker) && FileUtils.test (runtime.qmp, FileTest.EXISTS)) {
                try {
                    yield attach_qmp (10);
                    return;
                } catch (Error e) {
                    warning ("machines: %s still runs but does not answer: %s", machine.id, e.message);
                    return;
                }
            }
            on_gone ();
        }

        private void on_gone () {
            qmp = null;
            attached_usb.clear ();
            int fs = Tool.read_pid (runtime.fs_pid);
            if (Tool.owns_pid (fs, runtime.fs_socket)) Posix.kill (fs, Posix.Signal.TERM);
            clean_runtime ();
            state = MachineState.OFF;
            status_detail = "";
            stopped ();
        }

        public override async void reconnect () {
            int pid = Tool.read_pid (runtime.pid);
            if (!Tool.owns_pid (pid, marker) || !FileUtils.test (runtime.qmp, FileTest.EXISTS)) {
                if (FileUtils.test (runtime.dir, FileTest.IS_DIR) && !Tool.owns_pid (pid, marker)) clean_runtime ();
                return;
            }
            try {
                yield attach_qmp (3);
                bool fsd = Tool.owns_pid (Tool.read_pid (runtime.fs_pid), runtime.fs_socket);
                shared_mode = fsd ? SharedMode.VIRTIOFS : (machine.shared_folder != "" ? SharedMode.NINEP : SharedMode.NONE);
            } catch (Error e) {
                warning ("machines: cannot reconnect to %s: %s", machine.id, e.message);
            }
        }

        private async void start_virtiofsd (string binary) throws Error {
            FileUtils.unlink (runtime.fs_socket);
            string[] argv = QemuCommand.virtiofsd_args (binary, runtime.fs_socket, machine.shared_folder);
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE | SubprocessFlags.STDIN_INHERIT);
            launcher.set_child_setup (() => {
                Posix.setsid ();
            });
            var proc = launcher.spawnv (argv);
            string? pid = proc.get_identifier ();
            if (pid != null) FileUtils.set_contents (runtime.fs_pid, pid);
            for (int i = 0; i < 100; i++) {
                if (FileUtils.test (runtime.fs_socket, FileTest.EXISTS)) return;
                if (proc.get_identifier () == null) break;
                yield Tool.sleep (50);
            }
            if (!FileUtils.test (runtime.fs_socket, FileTest.EXISTS)) {
                proc.force_exit ();
                throw new IOError.FAILED (_("The shared folder service did not start."));
            }
        }

        public override async void start (string? restore_tag = null) throws Error {
            if (state.alive () || state == MachineState.STARTING) return;
            var host = backend.host;
            string? qemu = host.qemu_binary ();
            if (qemu == null) throw new IOError.NOT_FOUND (backend.unavailable_reason ());
            state = MachineState.STARTING;
            try {
                if (!runtime.fits ()) throw new IOError.FILENAME_TOO_LONG (_("The runtime folder path is too long for the control sockets."));
                DirUtils.create_with_parents (runtime.dir, 0700);
                foreach (string f in new string[] { runtime.qmp, runtime.vnc, runtime.pid }) FileUtils.unlink (f);
                if (!FileUtils.test (machine.disk_path (), FileTest.EXISTS)) yield backend.prepare (machine, null);
                if (machine.install_media != "" && !FileUtils.test (machine.install_media, FileTest.IS_REGULAR)) {
                    throw new IOError.NOT_FOUND (_("The installation image %s is missing. Remove it from the machine or put it back.").printf (Path.get_basename (machine.install_media)));
                }
                Firmware? fw = null;
                if (machine.uefi) fw = yield backend.ensure_vars (machine);
                shared_mode = SharedMode.NONE;
                if (machine.shared_folder != "" && FileUtils.test (machine.shared_folder, FileTest.IS_DIR)) {
                    string? fsd = host.virtiofsd_binary ();
                    if (fsd != null) {
                        try {
                            yield start_virtiofsd (fsd);
                            shared_mode = SharedMode.VIRTIOFS;
                        } catch (Error e) {
                            warning ("machines: virtiofsd: %s", e.message);
                            shared_mode = SharedMode.NINEP;
                        }
                    } else {
                        shared_mode = SharedMode.NINEP;
                    }
                }
                var cmd = new QemuCommand ();
                cmd.binary = qemu;
                cmd.arch = host.arch;
                cmd.kvm = host.kvm_available ();
                cmd.firmware = fw;
                cmd.shared = shared_mode;
                cmd.loadvm = restore_tag ?? "";
                yield Tool.run (cmd.build (machine, runtime));
                yield attach_qmp (40);
                machine.last_used = new DateTime.now_utc ().to_unix ();
            } catch (Error e) {
                int fs = Tool.read_pid (runtime.fs_pid);
                if (Tool.owns_pid (fs, runtime.fs_socket)) Posix.kill (fs, Posix.Signal.TERM);
                if (qmp == null) {
                    clean_runtime ();
                    state = MachineState.OFF;
                }
                throw e;
            }
        }

        private QmpClient require () throws Error {
            if (qmp == null) throw new QmpError.CLOSED (_("The machine is not running."));
            return qmp;
        }

        public override async void shutdown () throws Error {
            var c = require ();
            yield c.execute ("system_powerdown");
            state = MachineState.STOPPING;
        }

        public override async void force_off () throws Error {
            if (qmp != null) {
                try {
                    qmp.closing_expected = true;
                    yield qmp.execute ("quit");
                    return;
                } catch (Error e) {
                }
            }
            int pid = Tool.read_pid (runtime.pid);
            if (Tool.owns_pid (pid, marker)) Posix.kill (pid, Posix.Signal.TERM);
        }

        public override async void pause () throws Error {
            yield require ().execute ("stop");
            state = MachineState.PAUSED;
        }

        public override async void resume () throws Error {
            yield require ().execute ("cont");
            state = MachineState.RUNNING;
        }

        public override async void reset () throws Error {
            yield require ().execute ("system_reset");
        }

        private static void check_hmp (string output) throws Error {
            string o = output.strip ();
            if (o == "") return;
            if (o.down ().contains ("error") || o.down ().contains ("could not") || o.down ().contains ("not supported")) throw new IOError.FAILED (o);
        }

        private string[] images () {
            string[] list = { machine.disk_path () };
            if (machine.uefi && FileUtils.test (machine.vars_path (), FileTest.EXISTS)) list += machine.vars_path ();
            return list;
        }

        private async int64 state_size (string tag) {
            string img = backend.host.qemu_img_binary () ?? "qemu-img";
            int64 total = -1;
            foreach (string path in images ()) {
                try {
                    string json = yield Tool.run ({ img, "info", "-U", "--output=json", path });
                    var p = new Json.Parser ();
                    p.load_from_data (json);
                    var root = p.get_root ().get_object ();
                    if (!root.has_member ("snapshots")) continue;
                    var arr = root.get_array_member ("snapshots");
                    for (uint i = 0; i < arr.get_length (); i++) {
                        var o = arr.get_object_element (i);
                        if (o.get_string_member_with_default ("name", "") == tag) total = int64.max (total, 0) + o.get_int_member_with_default ("vm-state-size", 0);
                    }
                } catch (Error e) {
                }
            }
            return total;
        }

        public override async void take_snapshot (string tag) throws Error {
            if (qmp != null) {
                if (shared_mode == SharedMode.VIRTIOFS) throw new IOError.NOT_SUPPORTED (_("A running machine cannot be saved while a folder is shared with it through virtiofs. Shut it down to take a snapshot of the disk."));
                var before = state;
                string output = yield qmp.hmp ("savevm " + tag);
                if (before == MachineState.RUNNING && state == MachineState.PAUSED) {
                    try {
                        yield qmp.execute ("cont");
                    } catch (Error e) {
                    }
                    state = MachineState.RUNNING;
                }
                check_hmp (output);
                if ((yield state_size (tag)) <= 0) {
                    try {
                        yield qmp.hmp ("delvm " + tag);
                    } catch (Error e) {
                    }
                    throw new IOError.FAILED (output.strip () != "" ? output.strip () : _("The running state of the machine could not be saved."));
                }
                return;
            }
            string img = backend.host.qemu_img_binary () ?? "qemu-img";
            foreach (string path in images ()) yield Tool.run ({ img, "snapshot", "-c", tag, path });
        }

        public override async void revert_snapshot (string tag) throws Error {
            var snap = machine.find_snapshot (tag);
            if (qmp != null) {
                if (snap != null && !snap.with_state) throw new IOError.FAILED (_("This snapshot was taken while the machine was off. Shut the machine down to restore it."));
                check_hmp (yield qmp.hmp ("loadvm " + tag));
                yield qmp.execute ("cont");
                state = MachineState.RUNNING;
                return;
            }
            if (snap != null && snap.with_state) {
                yield start (tag);
                return;
            }
            string img = backend.host.qemu_img_binary () ?? "qemu-img";
            foreach (string path in images ()) yield Tool.run ({ img, "snapshot", "-a", tag, path });
        }

        public override async void delete_snapshot (string tag) throws Error {
            if (qmp != null) {
                check_hmp (yield qmp.hmp ("delvm " + tag));
                return;
            }
            string img = backend.host.qemu_img_binary () ?? "qemu-img";
            string[] paths = images ();
            for (int i = 0; i < paths.length; i++) {
                try {
                    yield Tool.run ({ img, "snapshot", "-d", tag, paths[i] });
                } catch (Error e) {
                    if (i == 0) throw e;
                }
            }
        }

        public override async bool screendump (string path) throws Error {
            if (qmp == null) return false;
            string tmp = path + ".part";
            var args = new Json.Object ();
            args.set_string_member ("filename", tmp);
            args.set_string_member ("format", "png");
            yield qmp.execute ("screendump", args);
            if (!FileUtils.test (tmp, FileTest.IS_REGULAR)) return false;
            return FileUtils.rename (tmp, path) == 0;
        }

        public override async void attach_usb (UsbDevice device) throws Error {
            var args = new Json.Object ();
            args.set_string_member ("driver", "usb-host");
            args.set_string_member ("id", device.qdev_id ());
            args.set_string_member ("bus", "xhci.0");
            args.set_int_member ("hostbus", device.bus);
            args.set_int_member ("hostaddr", device.address);
            yield require ().execute ("device_add", args);
            attached_usb.add (device.qdev_id ());
        }

        public override async void detach_usb (UsbDevice device) throws Error {
            var args = new Json.Object ();
            args.set_string_member ("id", device.qdev_id ());
            yield require ().execute ("device_del", args);
            attached_usb.remove (device.qdev_id ());
        }

        public override async void eject_media () throws Error {
            if (qmp == null) return;
            var args = new Json.Object ();
            args.set_string_member ("id", "cdrom0");
            args.set_boolean_member ("force", true);
            yield qmp.execute ("eject", args);
        }

        public override SocketConnectable? display_address () {
            if (!state.alive ()) return null;
            return new UnixSocketAddress (runtime.vnc);
        }
    }
}

namespace Singularity.Apps.Machines {

    public errordomain QmpError {
        CLOSED,
        COMMAND
    }

    public class QmpClient : Object {
        private class Pending {
            public SourceFunc callback;
            public Json.Object? reply;
        }

        private SocketConnection? conn;
        private DataInputStream? input;
        private OutputStream? output;
        private Cancellable cancel = new Cancellable ();
        private int next_id = 1;
        private Gee.HashMap<string, Pending> pending = new Gee.HashMap<string, Pending> ();
        private bool closed;

        public bool connected { get; private set; }
        public bool closing_expected { get; set; }

        public signal void event (string name, Json.Object? data);
        public signal void disconnected ();

        public async void open (string path) throws Error {
            var client = new SocketClient ();
            client.timeout = 10;
            conn = yield client.connect_async (new UnixSocketAddress (path), cancel);
            conn.socket.timeout = 0;
            input = new DataInputStream (conn.input_stream);
            input.newline_type = DataStreamNewlineType.ANY;
            output = conn.output_stream;
            var greeting = yield read_message ();
            if (!greeting.has_member ("QMP")) throw new QmpError.COMMAND (_("The machine did not answer as expected."));
            connected = true;
            reader.begin ();
            yield execute ("qmp_capabilities");
        }

        private async Json.Object read_message () throws Error {
            while (true) {
                string? line = yield input.read_line_async (Priority.DEFAULT, cancel, null);
                if (line == null) throw new QmpError.CLOSED ("closed");
                line = line.strip ();
                if (line == "") continue;
                var p = new Json.Parser ();
                p.load_from_data (line);
                var root = p.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) return root.get_object ();
            }
        }

        private async void reader () {
            try {
                while (!closed) {
                    var msg = yield read_message ();
                    if (msg.has_member ("event")) {
                        event (msg.get_string_member ("event"), msg.has_member ("data") ? msg.get_object_member ("data") : null);
                        continue;
                    }
                    if (!msg.has_member ("id")) continue;
                    string id = msg.get_string_member_with_default ("id", "");
                    Pending? p = null;
                    if (pending.unset (id, out p) && p != null) {
                        p.reply = msg;
                        p.callback ();
                    }
                }
            } catch (Error e) {
                if (!closed && !closing_expected) warning ("machines: control connection lost: %s", e.message);
            }
            close ();
        }

        public async Json.Node? execute (string command, Json.Object? arguments = null) throws Error {
            if (output == null || closed) throw new QmpError.CLOSED (_("The machine is not running."));
            string id = "m%d".printf (next_id++);
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("execute").add_string_value (command);
            if (arguments != null) {
                var node = new Json.Node (Json.NodeType.OBJECT);
                node.set_object (arguments);
                b.set_member_name ("arguments").add_value (node);
            }
            b.set_member_name ("id").add_string_value (id);
            b.end_object ();
            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            var call = new Pending ();
            call.callback = execute.callback;
            pending[id] = call;
            try {
                size_t written;
                output.write_all ((gen.to_data (null) + "\n").data, out written, cancel);
                output.flush (cancel);
            } catch (Error e) {
                pending.unset (id);
                close ();
                throw new QmpError.CLOSED (_("The machine is not running."));
            }
            yield;
            if (call.reply == null) throw new QmpError.CLOSED (_("The machine stopped."));
            if (call.reply.has_member ("error")) {
                var err = call.reply.get_object_member ("error");
                throw new QmpError.COMMAND (err.get_string_member_with_default ("desc", command));
            }
            return call.reply.has_member ("return") ? call.reply.get_member ("return").copy () : null;
        }

        public async string hmp (string command_line) throws Error {
            var args = new Json.Object ();
            args.set_string_member ("command-line", command_line);
            var r = yield execute ("human-monitor-command", args);
            if (r != null && r.get_value_type () == typeof (string)) return r.get_string ();
            return "";
        }

        public void close () {
            if (closed) return;
            closed = true;
            connected = false;
            cancel.cancel ();
            if (conn != null) {
                try {
                    conn.close ();
                } catch (Error e) {
                }
            }
            var waiting = new Gee.ArrayList<Pending> ();
            waiting.add_all (pending.values);
            pending.clear ();
            foreach (var p in waiting) p.callback ();
            disconnected ();
        }
    }
}

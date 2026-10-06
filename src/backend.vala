namespace Singularity.Apps.Machines {

    public enum MachineState {
        OFF,
        PREPARING,
        STARTING,
        RUNNING,
        PAUSED,
        STOPPING;

        public string label () {
            switch (this) {
                case PREPARING: return _("Preparing");
                case STARTING: return _("Starting");
                case RUNNING: return _("Running");
                case PAUSED: return _("Paused");
                case STOPPING: return _("Shutting Down");
                default: return _("Off");
            }
        }

        public bool alive () {
            return this == RUNNING || this == PAUSED || this == STOPPING;
        }
    }

    public class UsbDevice : Object {
        public string sysfs_name { get; set; default = ""; }
        public int bus { get; set; }
        public int address { get; set; }
        public string vendor_id { get; set; default = ""; }
        public string product_id { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public bool writable { get; set; }

        public string qdev_id () {
            return "usb-%03d-%03d".printf (bus, address);
        }

        public static Gee.ArrayList<UsbDevice> list (string root = "/sys/bus/usb/devices") {
            var result = new Gee.ArrayList<UsbDevice> ();
            try {
                var d = Dir.open (root);
                string? name;
                while ((name = d.read_name ()) != null) {
                    if (name.has_prefix ("usb") || name.contains (":")) continue;
                    string dir = Path.build_filename (root, name);
                    string cls = read (dir, "bDeviceClass");
                    if (cls == "09") continue;
                    var dev = new UsbDevice ();
                    dev.sysfs_name = name;
                    dev.bus = int.parse (read (dir, "busnum"));
                    dev.address = int.parse (read (dir, "devnum"));
                    dev.vendor_id = read (dir, "idVendor");
                    dev.product_id = read (dir, "idProduct");
                    string product = read (dir, "product");
                    string maker = read (dir, "manufacturer");
                    if (product != "" && maker != "" && !product.has_prefix (maker)) dev.label = "%s %s".printf (maker, product);
                    else if (product != "") dev.label = product;
                    else dev.label = "%s:%s".printf (dev.vendor_id, dev.product_id);
                    string node = "/dev/bus/usb/%03d/%03d".printf (dev.bus, dev.address);
                    dev.writable = Posix.access (node, Posix.R_OK | Posix.W_OK) == 0;
                    if (dev.bus > 0 && dev.address > 0) result.add (dev);
                }
            } catch (Error e) {
            }
            result.sort ((a, b) => strcmp (a.label.down (), b.label.down ()));
            return result;
        }

        private static string read (string dir, string file) {
            try {
                string s;
                FileUtils.get_contents (Path.build_filename (dir, file), out s);
                return s.strip ();
            } catch (Error e) {
                return "";
            }
        }
    }

    public abstract class MachineController : Object {
        public Machine machine { get; construct; }
        public MachineState state { get; protected set; default = MachineState.OFF; }
        public string status_detail { get; protected set; default = ""; }
        public bool accelerated { get; protected set; }
        public SharedMode shared_mode { get; protected set; default = SharedMode.NONE; }
        public Gee.HashSet<string> attached_usb = new Gee.HashSet<string> ();

        public signal void failed (string message);
        public signal void stopped ();

        public abstract async void start (string? restore_tag = null) throws Error;
        public abstract async void shutdown () throws Error;
        public abstract async void force_off () throws Error;
        public abstract async void pause () throws Error;
        public abstract async void resume () throws Error;
        public abstract async void reset () throws Error;
        public abstract async void take_snapshot (string tag) throws Error;
        public abstract async void revert_snapshot (string tag) throws Error;
        public abstract async void delete_snapshot (string tag) throws Error;
        public abstract async bool screendump (string path) throws Error;
        public abstract async void attach_usb (UsbDevice device) throws Error;
        public abstract async void detach_usb (UsbDevice device) throws Error;
        public abstract async void eject_media () throws Error;
        public abstract SocketConnectable? display_address ();
        public abstract async void reconnect ();
    }

    public abstract class MachineBackend : Object {
        public HostConfig host { get; construct; }

        public abstract string id { get; }
        public abstract string label { get; }
        public abstract bool available ();
        public abstract string unavailable_reason ();
        public abstract async void prepare (Machine m, Cancellable? cancel) throws Error;
        public abstract MachineController controller (Machine m);
        public abstract async void destroy (Machine m) throws Error;
    }

    namespace Backends {
        public MachineBackend create (string id, HostConfig host) {
#if HAVE_LIBVIRT
            if (id == "libvirt") return new LibvirtBackend (host);
#endif
            return new QemuBackend (host);
        }

        public string[] known () {
#if HAVE_LIBVIRT
            return { "qemu", "libvirt" };
#else
            return { "qemu" };
#endif
        }

        public MachineBackend choose (HostConfig host) {
            if (host.backend == "libvirt" || host.backend == "qemu") return create (host.backend, host);
            var qemu = create ("qemu", host);
            if (qemu.available ()) return qemu;
            var lv = create ("libvirt", host);
            if (lv.available ()) return lv;
            return qemu;
        }
    }
}

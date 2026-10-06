namespace Singularity.Apps.Machines {

    namespace DomainXml {
        public string domain_name (Machine m) {
            return "singularity-machines-" + m.id;
        }

        private string esc (string s) {
            return Markup.escape_text (s);
        }

        public string build (Machine m, Firmware? fw, RuntimePaths rt, bool kvm, string arch) {
            bool windows = m.family == "winnt";
            var sb = new StringBuilder ();
            sb.append_printf ("<domain type='%s'>\n", kvm ? "kvm" : "qemu");
            sb.append_printf ("  <name>%s</name>\n", esc (domain_name (m)));
            sb.append_printf ("  <title>%s</title>\n", esc (m.title ()));
            sb.append_printf ("  <memory unit='MiB'>%d</memory>\n", m.memory_mib);
            sb.append_printf ("  <vcpu>%d</vcpu>\n", m.cpus);
            if (m.uefi && fw != null) {
                sb.append ("  <os>\n");
                sb.append_printf ("    <type arch='%s' machine='q35'>hvm</type>\n", esc (arch));
                sb.append_printf ("    <loader readonly='yes' type='pflash'>%s</loader>\n", esc (fw.code));
                if (fw.vars != "") sb.append_printf ("    <nvram template='%s'>%s</nvram>\n", esc (fw.vars), esc (Path.build_filename (m.dir, "efivars.fd")));
                sb.append ("  </os>\n");
            } else {
                sb.append_printf ("  <os>\n    <type arch='%s' machine='q35'>hvm</type>\n  </os>\n", esc (arch));
            }
            sb.append ("  <features><acpi/><apic/><vmport state='off'/></features>\n");
            sb.append_printf ("  <cpu mode='%s'/>\n", kvm ? "host-passthrough" : "maximum");
            sb.append_printf ("  <clock offset='%s'/>\n", windows ? "localtime" : "utc");
            if (m.shared_folder != "") sb.append ("  <memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>\n");
            sb.append ("  <devices>\n");
            sb.append_printf ("    <disk type='file' device='disk'><driver name='qemu' type='qcow2' discard='unmap'/><source file='%s'/><target dev='%s' bus='%s'/><boot order='2'/></disk>\n",
                esc (m.disk_path ()), windows ? "sda" : "vda", windows ? "sata" : "virtio");
            if (m.install_media != "") {
                sb.append_printf ("    <disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='%s'/><target dev='sdc' bus='sata'/><readonly/><boot order='1'/></disk>\n", esc (m.install_media));
            }
            sb.append_printf ("    <interface type='user'><model type='%s'/></interface>\n", windows ? "e1000e" : "virtio");
            sb.append ("    <controller type='usb' model='qemu-xhci'/>\n");
            sb.append ("    <input type='tablet' bus='usb'/>\n");
            sb.append_printf ("    <graphics type='vnc' socket='%s'/>\n", esc (rt.vnc));
            sb.append_printf ("    <video><model type='%s'/></video>\n", windows ? "vga" : "virtio");
            sb.append ("    <channel type='qemu-vdagent'><source><clipboard copypaste='yes'/></source><target type='virtio' name='com.redhat.spice.0'/></channel>\n");
            sb.append ("    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>\n");
            if (m.shared_folder != "") {
                sb.append_printf ("    <filesystem type='mount' accessmode='passthrough'><driver type='virtiofs'/><source dir='%s'/><target dir='shared'/></filesystem>\n", esc (m.shared_folder));
            }
            sb.append ("  </devices>\n");
            sb.append ("</domain>\n");
            return sb.str;
        }

        public string hostdev (UsbDevice d) {
            return "<hostdev mode='subsystem' type='usb'><source><address bus='%d' device='%d'/></source></hostdev>".printf (d.bus, d.address);
        }
    }

#if HAVE_LIBVIRT
    public class LibvirtBackend : MachineBackend {
        public LibvirtBackend (HostConfig host) {
            Object (host: host);
        }

        public override string id {
            get { return "libvirt"; }
        }

        public override string label {
            get { return "libvirt"; }
        }

        public override bool available () {
            return host.virsh_binary () != null && host.qemu_img_binary () != null;
        }

        public override string unavailable_reason () {
            if (host.virsh_binary () == null) return _("libvirt is not installed.");
            return _("The qemu-img tool is not installed.");
        }

        public async string virsh (string[] args) throws Error {
            string[] argv = { host.virsh_binary () ?? "virsh", "-q", "-c", host.libvirt_uri };
            foreach (string a in args) argv += a;
            return yield Tool.run (argv);
        }

        public async void define (Machine m) throws Error {
            var rt = RuntimePaths.for_machine (host.runtime_root (), m.id);
            DirUtils.create_with_parents (rt.dir, 0700);
            string xml = DomainXml.build (m, m.uefi ? host.find_firmware () : null, rt, host.kvm_available (), host.arch);
            string path = Path.build_filename (m.dir, "domain.xml");
            FileUtils.set_contents (path, xml);
            yield virsh ({ "define", path });
        }

        public override async void prepare (Machine m, Cancellable? cancel) throws Error {
            string? img = host.qemu_img_binary ();
            if (img == null) throw new IOError.NOT_FOUND (unavailable_reason ());
            if (!FileUtils.test (m.disk_path (), FileTest.EXISTS)) {
                if (m.source_image != "") yield Tool.run (QemuCommand.import_disk_args (img, m.source_image, m.disk_path ()), cancel);
                else yield Tool.run (QemuCommand.create_disk_args (img, m.disk_path (), m.disk_gib), cancel);
            }
            yield define (m);
        }

        public override MachineController controller (Machine m) {
            return new LibvirtController (m, this);
        }

        public override async void destroy (Machine m) throws Error {
            try {
                yield virsh ({ "destroy", DomainXml.domain_name (m) });
            } catch (Error e) {
            }
            yield virsh ({ "undefine", "--nvram", "--snapshots-metadata", DomainXml.domain_name (m) });
        }
    }

    public class LibvirtController : MachineController {
        public LibvirtBackend backend { get; construct; }
        private uint poll_id;
        private string name;

        public LibvirtController (Machine m, LibvirtBackend backend) {
            Object (machine: m, backend: backend);
            name = DomainXml.domain_name (m);
        }

        private async void refresh () {
            try {
                string st = (yield backend.virsh ({ "domstate", name })).strip ();
                var before = state;
                if (st == "running") state = MachineState.RUNNING;
                else if (st == "paused" || st == "pmsuspended") state = MachineState.PAUSED;
                else if (st == "in shutdown") state = MachineState.STOPPING;
                else state = MachineState.OFF;
                if (before.alive () && state == MachineState.OFF) stopped ();
            } catch (Error e) {
                state = MachineState.OFF;
            }
            if (state == MachineState.OFF && poll_id != 0) {
                Source.remove (poll_id);
                poll_id = 0;
            } else if (state != MachineState.OFF && poll_id == 0) {
                poll_id = Timeout.add_seconds (2, () => {
                    refresh.begin ();
                    return Source.CONTINUE;
                });
            }
        }

        public override async void reconnect () {
            yield refresh ();
        }

        public override async void start (string? restore_tag = null) throws Error {
            state = MachineState.STARTING;
            try {
                yield backend.define (machine);
                if (restore_tag != null) yield backend.virsh ({ "snapshot-revert", name, restore_tag, "--running" });
                else yield backend.virsh ({ "start", name });
            } catch (Error e) {
                state = MachineState.OFF;
                throw e;
            }
            machine.last_used = new DateTime.now_utc ().to_unix ();
            yield refresh ();
        }

        public override async void shutdown () throws Error {
            yield backend.virsh ({ "shutdown", name });
            state = MachineState.STOPPING;
        }

        public override async void force_off () throws Error {
            yield backend.virsh ({ "destroy", name });
            yield refresh ();
        }

        public override async void pause () throws Error {
            yield backend.virsh ({ "suspend", name });
            yield refresh ();
        }

        public override async void resume () throws Error {
            yield backend.virsh ({ "resume", name });
            yield refresh ();
        }

        public override async void reset () throws Error {
            yield backend.virsh ({ "reset", name });
        }

        public override async void take_snapshot (string tag) throws Error {
            yield backend.virsh ({ "snapshot-create-as", name, tag });
        }

        public override async void revert_snapshot (string tag) throws Error {
            yield backend.virsh ({ "snapshot-revert", name, tag });
            yield refresh ();
        }

        public override async void delete_snapshot (string tag) throws Error {
            yield backend.virsh ({ "snapshot-delete", name, tag });
        }

        public override async bool screendump (string path) throws Error {
            if (!state.alive ()) return false;
            string tmp = path + ".part";
            yield backend.virsh ({ "screenshot", name, tmp });
            return FileUtils.rename (tmp, path) == 0;
        }

        private async void hostdev (UsbDevice d, bool attach) throws Error {
            string path = Path.build_filename (machine.dir, "usb.xml");
            FileUtils.set_contents (path, DomainXml.hostdev (d));
            yield backend.virsh ({ attach ? "attach-device" : "detach-device", name, path, "--live" });
            FileUtils.unlink (path);
        }

        public override async void attach_usb (UsbDevice device) throws Error {
            yield hostdev (device, true);
            attached_usb.add (device.qdev_id ());
        }

        public override async void detach_usb (UsbDevice device) throws Error {
            yield hostdev (device, false);
            attached_usb.remove (device.qdev_id ());
        }

        public override async void eject_media () throws Error {
            if (!state.alive ()) return;
            yield backend.virsh ({ "change-media", name, "sdc", "--eject", "--live" });
        }

        public override SocketConnectable? display_address () {
            if (!state.alive ()) return null;
            return new UnixSocketAddress (RuntimePaths.for_machine (backend.host.runtime_root (), machine.id).vnc);
        }
    }
#endif
}

using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Machines {

    public class DetailsPage : Box {
        public signal void open_snapshots ();
        public signal void delete_requested (Machine m);

        private weak MachinesWindow window;
        private MachineManager manager;
        private Box content;
        private Machine? machine;
        private bool busy;

        public DetailsPage (MachinesWindow window, MachineManager manager) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.window = window;
            this.manager = manager;
            content = new Box (Orientation.VERTICAL, 18);
            content.add_css_class ("machine-details");
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = new Clamp (content, 640);
            apply_view_edge (scroll);
            append (scroll);
        }

        public void show_machine (Machine m) {
            machine = m;
            rebuild ();
        }

        private void rebuild () {
            Widget? child;
            while ((child = content.get_first_child ()) != null) content.remove (child);
            var m = machine;
            if (m == null) return;
            var c = manager.controller (m);
            bool alive = c.state.alive ();

            var overview = new PreferencesGroup (m.title (), m.os_name != "" && m.os_name != m.title () ? m.os_name : null);
            var state_row = new ActionRow (_("State"), c.state.label (), "dev.sinty.machines");
            overview.add_row (state_row);
            var snaps = new ActionRow (_("Snapshots"), m.snapshots.size == 0 ? _("Save the machine as it is and come back to it later") : ngettext ("%d snapshot", "%d snapshots", m.snapshots.size).printf (m.snapshots.size), "dev.sinty.machines-snapshot");
            var go = new Image.from_icon_name ("go-next-symbolic");
            snaps.add_suffix (go);
            snaps.activatable = true;
            snaps.activated.connect (() => open_snapshots ());
            overview.add_row (snaps);
            content.append (overview);

            var resources = new PreferencesGroup (_("Resources"), alive ? _("Shut the machine down to change memory and processors.") : null);
            var mem = new SpinRow (_("Memory (GiB)"), null, 0.5, double.max (1, Math.floor (manager.limits.memory_mib / 512.0) / 2), 0.5, Math.round (m.memory_mib / 512.0) / 2);
            mem.sensitive = !alive;
            mem.spin_btn.value_changed.connect (() => {
                m.memory_mib = (int) Math.round (mem.value * 1024);
                manager.store.put (m);
            });
            resources.add_row (mem);
            var cpus = new SpinRow (_("Processors"), null, 1, int.max (1, manager.limits.cpus), 1, m.cpus);
            cpus.sensitive = !alive;
            cpus.spin_btn.value_changed.connect (() => {
                m.cpus = (int) cpus.value;
                manager.store.put (m);
            });
            resources.add_row (cpus);
            var resize = new SwitchRow (_("Match Window Size"), _("Ask the system to change its resolution when the window is resized"), m.resize_guest);
            resize.switch_btn.notify["active"].connect (() => {
                m.resize_guest = resize.active;
                manager.store.put (m);
            });
            resources.add_row (resize);
            content.append (resources);

            var sharing = new PreferencesGroup (_("Shared Folder"));
            string share_sub;
            if (m.shared_folder == "") share_sub = _("Not shared");
            else if (alive && c.shared_mode == SharedMode.VIRTIOFS) share_sub = _("%s, mount it in the system with: mount -t virtiofs shared /mnt").printf (m.shared_folder);
            else if (alive && c.shared_mode == SharedMode.NINEP) share_sub = _("%s, mount it in the system with: mount -t 9p -o trans=virtio shared /mnt").printf (m.shared_folder);
            else share_sub = _("%s, available the next time the machine starts").printf (m.shared_folder);
            var share_row = new ActionRow (m.shared_folder != "" ? Path.get_basename (m.shared_folder) : _("Folder"), share_sub, "folder");
            var pick = new Button.with_label (m.shared_folder != "" ? _("Change…") : _("Choose…"));
            pick.valign = Align.CENTER;
            pick.sensitive = !alive;
            pick.clicked.connect (() => choose_folder ());
            share_row.add_suffix (pick);
            if (m.shared_folder != "") {
                var stop = new Button.with_label (_("Stop Sharing"));
                stop.valign = Align.CENTER;
                stop.sensitive = !alive;
                stop.clicked.connect (() => {
                    m.shared_folder = "";
                    manager.store.put (m);
                    rebuild ();
                });
                share_row.add_suffix (stop);
            }
            sharing.add_row (share_row);
            content.append (sharing);

            var usb = new PreferencesGroup (_("USB Devices"), alive ? _("Devices you turn on here are taken away from this computer while the machine uses them.") : _("Start the machine to give it a USB device."));
            var devices = UsbDevice.list (manager.host.usb_root);
            foreach (var d in devices) {
                bool on = c.attached_usb.contains (d.qdev_id ());
                var row = new SwitchRow (d.label, d.writable ? "%s:%s".printf (d.vendor_id, d.product_id) : _("You do not have permission to use this device"), on);
                row.sensitive = alive && d.writable;
                row.switch_btn.notify["active"].connect (() => {
                    if (busy || row.active == c.attached_usb.contains (d.qdev_id ())) return;
                    toggle_usb.begin (c, d, row.active);
                });
                usb.add_row (row);
            }
            if (devices.size == 0) usb.add_row (new ActionRow (_("No USB devices are connected"), null, "drive-removable-media"));
            content.append (usb);

            if (m.install_media != "") {
                var media = new PreferencesGroup (_("Installation Image"));
                var row = new ActionRow (Path.get_basename (m.install_media), _("Remove it once the system is installed on the disk"), "media-optical");
                var eject = new Button.with_label (_("Remove"));
                eject.valign = Align.CENTER;
                eject.clicked.connect (() => {
                    c.eject_media.begin ((o, res) => {
                        try {
                            c.eject_media.end (res);
                        } catch (Error e) {
                            warning ("machines: %s", e.message);
                        }
                        m.install_media = "";
                        manager.store.put (m);
                        rebuild ();
                    });
                });
                row.add_suffix (eject);
                media.add_row (row);
                content.append (media);
            }

            var system = new PreferencesGroup (_("System"));
            system.add_row (new ActionRow (_("Firmware"), m.uefi ? _("UEFI") : _("BIOS")));
            string accel = alive ? (c.accelerated ? _("Hardware (KVM)") : _("Software emulation")) : (manager.host.kvm_available () ? _("Hardware (KVM)") : _("Software emulation"));
            system.add_row (new ActionRow (_("Acceleration"), accel));
            system.add_row (new ActionRow (_("Runs With"), manager.backend_for (m).label));
            system.add_row (new ActionRow (_("Disk"), m.disk_path ()));
            int sdb = m.forward_for_guest (5555);
            if (sdb > 0) system.add_row (new ActionRow (_("Debug Bridge"), "sdb pair 127.0.0.1:%d".printf (sdb), "utilities-terminal"));
            content.append (system);

            var danger = new PreferencesGroup (_("Remove"));
            var del_row = new ActionRow (_("Delete Machine"), _("Removes the machine with its disk and snapshots"), "user-trash-full");
            var del = new Button.with_label (_("Delete"));
            del.add_css_class ("destructive-action");
            del.valign = Align.CENTER;
            del.clicked.connect (() => delete_requested (m));
            del_row.add_suffix (del);
            danger.add_row (del_row);
            content.append (danger);
        }

        private async void toggle_usb (MachineController c, UsbDevice d, bool on) {
            busy = true;
            try {
                if (on) yield c.attach_usb (d);
                else yield c.detach_usb (d);
            } catch (Error e) {
                window.report (on ? _("Could Not Connect %s").printf (d.label) : _("Could Not Disconnect %s").printf (d.label), e);
            }
            busy = false;
            rebuild ();
        }

        private void choose_folder () {
            var m = machine;
            if (m == null) return;
            var dialog = new FileDialog ();
            dialog.title = _("Choose a Folder to Share");
            dialog.select_folder.begin (window, null, (o, res) => {
                try {
                    var f = dialog.select_folder.end (res);
                    if (f != null && f.get_path () != null) {
                        m.shared_folder = f.get_path ();
                        manager.store.put (m);
                        rebuild ();
                    }
                } catch (Error e) {
                }
            });
        }
    }

    public class SnapshotsPage : Box {
        private weak MachinesWindow window;
        private MachineManager manager;
        private Stack stack;
        private Box list_box;
        private WelcomePage empty;
        private Machine? machine;
        private bool working;

        public SnapshotsPage (MachinesWindow window, MachineManager manager) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.window = window;
            this.manager = manager;
            stack = new Stack ();
            stack.vexpand = true;
            empty = new WelcomePage ();
            empty.is_section = true;
            empty.app_icon_name = "dev.sinty.machines-snapshot";
            empty.title = _("Snapshots");
            empty.subtitle = _("A snapshot keeps the disk and, while the machine runs, everything that is open. Go back to it whenever you want.");
            empty.add_action ("dev.sinty.machines-snapshot", _("Take a Snapshot"), _("Save the machine as it is now"), () => take ());
            stack.add_named (empty, "empty");
            list_box = new Box (Orientation.VERTICAL, 18);
            list_box.add_css_class ("machine-details");
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = new Clamp (list_box, 640);
            apply_view_edge (scroll);
            stack.add_named (scroll, "list");
            append (stack);
        }

        public void show_machine (Machine m) {
            machine = m;
            rebuild ();
        }

        private void rebuild () {
            Widget? child;
            while ((child = list_box.get_first_child ()) != null) list_box.remove (child);
            var m = machine;
            if (m == null) return;
            stack.visible_child_name = m.snapshots.size == 0 ? "empty" : "list";
            var group = new PreferencesGroup (_("Snapshots of %s").printf (m.title ()), _("Restoring a snapshot replaces the current state of the machine."));
            var sorted = new Gee.ArrayList<SnapshotInfo> ();
            sorted.add_all (m.snapshots);
            sorted.sort ((a, b) => a.created > b.created ? -1 : (a.created < b.created ? 1 : 0));
            foreach (var s in sorted) {
                var row = new ActionRow (s.name, s.with_state ? _("Disk and running state") : _("Disk only"), "dev.sinty.machines-snapshot");
                var restore = new Button.with_label (_("Restore"));
                restore.valign = Align.CENTER;
                restore.sensitive = !working;
                restore.clicked.connect (() => confirm_restore (s));
                row.add_suffix (restore);
                var del = new Button.from_icon_name ("user-trash-symbolic");
                del.tooltip_text = _("Delete Snapshot");
                del.valign = Align.CENTER;
                del.sensitive = !working;
                del.clicked.connect (() => remove_snapshot.begin (s));
                row.add_suffix (del);
                group.add_row (row);
            }
            list_box.append (group);
        }

        public void take () {
            var m = machine;
            if (m == null || working) return;
            var c = manager.controller (m);
            var s = new SnapshotInfo ();
            s.created = new DateTime.now_utc ().to_unix ();
            s.tag = "snap-%s".printf (new DateTime.now_utc ().format ("%Y%m%d-%H%M%S"));
            s.name = new DateTime.now_local ().format (_("Snapshot of %e %B, %H:%M")).replace ("  ", " ");
            s.with_state = c.state.alive ();
            working = true;
            window.add_toast (new Toast (_("Taking a snapshot of %s").printf (m.title ())));
            c.take_snapshot.begin (s.tag, (o, res) => {
                working = false;
                try {
                    c.take_snapshot.end (res);
                    m.snapshots.add (s);
                    manager.store.put (m);
                    window.add_toast (new Toast (_("Snapshot saved")));
                } catch (Error e) {
                    window.report (_("Could Not Take a Snapshot"), e);
                }
                rebuild ();
            });
        }

        private void confirm_restore (SnapshotInfo s) {
            var m = machine;
            if (m == null) return;
            var dlg = new ConfirmDialog ((Gtk.Application) window.application, _("Restore %s?").printf (s.name), "dev.sinty.machines-snapshot",
                _("The machine goes back to how it was when the snapshot was taken. Changes made since then are lost."), _("Restore"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = window;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) restore.begin (m, s);
            });
            dlg.present ();
        }

        private async void restore (Machine m, SnapshotInfo s) {
            var c = manager.controller (m);
            working = true;
            rebuild ();
            try {
                yield c.revert_snapshot (s.tag);
                window.add_toast (new Toast (_("%s was restored").printf (s.name)));
            } catch (Error e) {
                window.report (_("Could Not Restore the Snapshot"), e);
            }
            working = false;
            rebuild ();
            if (c.state.alive ()) window.open_machine (m);
        }

        private async void remove_snapshot (SnapshotInfo s) {
            var m = machine;
            if (m == null) return;
            var c = manager.controller (m);
            working = true;
            rebuild ();
            try {
                yield c.delete_snapshot (s.tag);
                m.snapshots.remove (s);
                manager.store.put (m);
            } catch (Error e) {
                window.report (_("Could Not Delete the Snapshot"), e);
            }
            working = false;
            rebuild ();
        }
    }
}

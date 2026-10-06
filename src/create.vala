using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Machines {

    public class NewMachineDialog : ConfirmDialog {
        public signal void created (Machine m);
        public signal void change_source ();

        private MachineManager manager;
        private string path;
        private Detection detection;
        private EntryRow name_row;
        private SpinRow memory_row;
        private SpinRow cpu_row;
        private SpinRow disk_row;
        private SwitchRow uefi_row;

        public NewMachineDialog (MachinesApp app, MachineManager manager, string path, Detection detection) {
            base (app, _("New Machine"), null, null, _("Create"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.manager = manager;
            this.path = path;
            this.detection = detection;
            set_default_size (460, 0);

            var system = new PreferencesGroup (_("System"));
            string os_title = detection.os_name != "" ? detection.os_name : _("Unknown System");
            var os_row = new ActionRow (os_title, "%s\n%s".printf (Path.get_basename (path), describe (detection)), detection.is_disk_image ? "drive-harddisk" : "media-optical");
            os_row.tooltip_text = detection.volume_id != "" ? _("Disc label: %s").printf (detection.volume_id) : null;
            var change = new Button.with_label (_("Change…"));
            change.valign = Align.CENTER;
            change.clicked.connect (() => {
                change_source ();
                close_dialog ();
            });
            os_row.add_suffix (change);
            system.add_row (os_row);
            custom_area.append (system);

            var group = new PreferencesGroup (_("Machine"));
            name_row = new EntryRow (_("Name"));
            name_row.text = unique_name (os_title);
            group.add_row (name_row);
            double max_mem = double.max (1, (double) manager.limits.memory_mib / 1024.0);
            memory_row = new SpinRow (_("Memory (GiB)"), null, 0.5, Math.floor (max_mem * 2) / 2, 0.5, round_half (detection.memory_mib / 1024.0));
            group.add_row (memory_row);
            cpu_row = new SpinRow (_("Processors"), null, 1, int.max (1, manager.limits.cpus), 1, detection.cpus);
            group.add_row (cpu_row);
            disk_row = new SpinRow (_("Disk Size (GiB)"), null, 1, 4096, 1, detection.disk_gib);
            disk_row.visible = !detection.is_disk_image;
            group.add_row (disk_row);
            var fw = manager.host.find_firmware ();
            string uefi_hint;
            if (fw == null) uefi_hint = _("No UEFI firmware was found on this computer");
            else if (detection.needs_efi) uefi_hint = _("This system only starts with UEFI");
            else uefi_hint = _("Start with UEFI instead of a classic BIOS");
            uefi_row = new SwitchRow (_("UEFI Firmware"), uefi_hint, fw != null && (detection.prefer_efi || detection.needs_efi || app.settings.get_boolean ("prefer-uefi")));
            uefi_row.sensitive = fw != null && !detection.needs_efi;
            group.add_row (uefi_row);
            custom_area.append (group);

            var hint = new Label (manager.host.kvm_available () ? _("Runs with hardware acceleration.") : _("Hardware acceleration is not available, so the machine runs slowly in software emulation."));
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.wrap = true;
            hint.max_width_chars = 48;
            custom_area.append (hint);

            name_row.entry_changed.connect (() => primary_sensitive = name_row.text.strip () != "");
            response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) create ();
            });
        }

        private static double round_half (double v) {
            return double.max (0.5, Math.round (v * 2) / 2);
        }

        public static string describe (Detection d) {
            switch (d.source) {
                case DetectionSource.OSINFO_MEDIA:
                    return _("Recognized from the disc label");
                case DetectionSource.OSINFO_DISTRO:
                    return d.volume_id != "" ? _("Recognized from the disc label, closest known release") : _("Recognized from the file name");
                case DetectionSource.HEURISTIC:
                    return d.volume_id != "" ? _("Guessed from the disc label") : _("Guessed from the file name");
                default:
                    return _("Not recognized, generic settings are used");
            }
        }

        private string unique_name (string base_name) {
            string candidate = base_name;
            int n = 2;
            bool taken = true;
            while (taken) {
                taken = false;
                foreach (var m in manager.store.items) {
                    if (m.name == candidate) {
                        taken = true;
                        candidate = "%s %d".printf (base_name, n++);
                        break;
                    }
                }
            }
            return candidate;
        }

        private void create () {
            var m = new Machine ();
            m.name = name_row.text.strip ();
            m.os_id = detection.os_id;
            m.os_name = detection.os_name;
            m.family = detection.family;
            m.backend = manager.backend.id;
            m.memory_mib = (int) Math.round (memory_row.value * 1024);
            m.cpus = (int) cpu_row.value;
            m.disk_gib = (int) disk_row.value;
            m.uefi = uefi_row.active && uefi_row.sensitive || detection.needs_efi;
            if (detection.is_disk_image) m.source_image = path;
            else m.install_media = path;
            m.created = new DateTime.now_utc ().to_unix ();
            m.last_used = m.created;
            try {
                manager.store.allocate_dir (m);
                manager.store.save (m);
            } catch (Error e) {
                warning ("machines: %s", e.message);
                return;
            }
            created (m);
        }
    }
}

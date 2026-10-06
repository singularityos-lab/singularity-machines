using Gtk;

namespace Singularity.Apps.Machines {

    public class MachinesApp : Singularity.Application {
        public GLib.Settings settings { get; private set; }
        public MachineManager manager { get; private set; }
        private MachinesWindow? window;
        private string? pending_open;
        private bool new_pending;

        public MachinesApp () {
            Object (application_id: "dev.sinty.machines", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("new-machine", 0, OptionFlags.NONE, OptionArg.NONE, _("Create a machine"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("new-machine")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("machines: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("new-machine", null);
                return 0;
            }
            new_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            settings = new GLib.Settings ("dev.sinty.machines");
            manager = new MachineManager (HostConfig.load ());
            manager.store.load ();
            manager.reconnect_all.begin ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);

            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New Machine…"), "win.new");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Close Window"), "win.close");
            f2.append (_("Quit"), "app.quit");
            file.append_section (null, f2);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            edit.append (_("Settings"), "app.settings");
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            view.append (_("Fit to Window"), "win.fit");
            view.append (_("Fullscreen"), "win.fullscreen");
            menu.append_submenu (_("View"), view);
            var machine = new GLib.Menu ();
            var m1 = new GLib.Menu ();
            m1.append (_("Pause or Resume"), "win.pause");
            m1.append (_("Shut Down"), "win.shutdown");
            m1.append (_("Restart"), "win.reset");
            m1.append (_("Force Off"), "win.force-off");
            machine.append_section (null, m1);
            var m2 = new GLib.Menu ();
            m2.append (_("Take a Snapshot"), "win.snapshot");
            m2.append (_("Send Ctrl+Alt+Del"), "win.send-ctrl-alt-del");
            m2.append (_("Machine Details"), "win.details");
            machine.append_section (null, m2);
            menu.append_submenu (_("Machine"), machine);
            set_menubar (menu);

            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.machines");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var new_machine = new SimpleAction ("new-machine", null);
            new_machine.activate.connect (() => {
                activate ();
                if (window != null) window.choose_source ();
            });
            add_action (new_machine);
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.new", { "<Control>n" });
            set_accels_for_action ("win.fullscreen", { "F11" });
        }

        public override void activate () {
            if (window == null) {
                window = new MachinesWindow (this);
                window.close_request.connect (() => {
                    window = null;
                    return false;
                });
            }
            window.present ();
            if (new_pending) {
                new_pending = false;
                window.choose_source ();
            }
            if (pending_open != null) {
                string path = pending_open;
                pending_open = null;
                window.create_from.begin (path);
            }
        }

        public override void open (File[] files, string hint) {
            if (files.length > 0 && files[0].get_path () != null) pending_open = files[0].get_path ();
            activate ();
        }

        private const string CSS = """
.machine-card {
    padding: 8px;
    border-radius: 18px;
    background: transparent;
}

.machine-card:hover .machine-thumb {
    box-shadow: 0 0 0 3px alpha(@accent_bg_color, 0.55), 0 6px 18px alpha(black, 0.18);
}

.machine-thumb {
    border-radius: 14px;
    background-color: #1c1f26;
    box-shadow: 0 4px 14px alpha(black, 0.16);
    transition: box-shadow var(--motion-duration-small, 140ms) var(--motion-curve-standard, ease);
}

.machine-thumb.off > .machine-picture {
    opacity: 0.55;
}

.machine-badge {
    font-size: 11px;
    font-weight: 700;
    padding: 2px 9px;
    border-radius: 99px;
    color: white;
    background-color: alpha(black, 0.6);
}

.machine-badge.running {
    background-color: alpha(#1baf7a, 0.92);
}

.machine-badge.paused {
    background-color: alpha(#e28a00, 0.92);
}

.machine-name {
    font-weight: 700;
}

.machine-stage {
    background-color: #0e1014;
}

.machine-status {
    padding: 28px 36px;
    border-radius: 24px;
    background-color: @window_bg_color;
    color: @window_fg_color;
    box-shadow: 0 10px 40px alpha(black, 0.35);
}

.machine-details {
    padding: 24px 24px 32px 24px;
}

.remote-display:focus-visible {
    outline: none;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-machines", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-machines", "UTF-8");
        Intl.textdomain ("singularity-machines");
        return new MachinesApp ().run (args);
    }
}

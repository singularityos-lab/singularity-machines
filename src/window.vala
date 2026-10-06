using Gtk;
using Singularity.Widgets;
using Singularity.Remote;

namespace Singularity.Apps.Machines {

    public class MachinesWindow : Singularity.Widgets.Window {
        private MachinesApp app;
        private MachineManager manager;
        private Stack stack;
        private FlowBox grid;
        private Gee.HashMap<string, MachineCard> cards = new Gee.HashMap<string, MachineCard> ();
        private RemoteDisplay screen_view;
        private ScrolledWindow display_scroll;
        private Box status_box;
        private Spinner spinner;
        private Label status_title;
        private Label status_detail;
        private Button status_primary;
        private Button status_back;
        private VncSession? session;
        private Machine? current;
        private DetailsPage details;
        private SnapshotsPage snapshots;
        private Button add_bubble;
        private Button back_bubble;
        private Button pause_bubble;
        private Button power_bubble;
        private Button snapshot_bubble;
        private Button details_bubble;
        private Button keys_bubble;
        private Button fit_bubble;
        private Button full_bubble;
        private Button take_bubble;
        private Gee.ArrayList<Widget> display_bubbles = new Gee.ArrayList<Widget> ();
        private Gee.ArrayList<SimpleAction> machine_actions = new Gee.ArrayList<SimpleAction> ();
        private SimpleAction fit_action;
        private uint thumb_timer;
        private string last_clipboard = "";
        private bool inhibiting;
        private int connect_attempt;

        public MachinesWindow (MachinesApp app) {
            Object (application: app);
            this.app = app;
            manager = app.manager;
            title = _("Machines");
            set_default_size (1100, 720);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            var motion = Singularity.Motion.get_default ();
            uint page_ms = motion.scale (Singularity.Motion.Duration.PAGE.ms ());
            stack.transition_duration = motion.is_reduced () ? uint.min (page_ms, Singularity.Motion.Duration.SMALL.ms ()) : page_ms;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_grid (), "grid");
            stack.add_named (build_display (), "display");
            details = new DetailsPage (this, manager);
            stack.add_named (details, "details");
            snapshots = new SnapshotsPage (this, manager);
            stack.add_named (snapshots, "snapshots");
            set_content (stack);

            details.open_snapshots.connect (() => show_page ("snapshots"));
            details.delete_requested.connect ((m) => confirm_delete (m));

            add_bubble = add_bubble_icon ("list-add-symbolic", _("New Machine"), () => choose_source ());
            back_bubble = add_bubble_icon ("go-previous-symbolic", _("Back"), () => go_back ());
            pause_bubble = add_bubble_icon ("media-playback-pause-symbolic", _("Pause"), () => toggle_pause ());
            display_bubbles.add (pause_bubble);
            power_bubble = add_bubble_icon ("system-shutdown-symbolic", _("Power"), () => power_menu (power_bubble));
            display_bubbles.add (power_bubble);
            snapshot_bubble = add_bubble_icon ("document-save-symbolic", _("Take a Snapshot"), () => quick_snapshot ());
            display_bubbles.add (snapshot_bubble);
            keys_bubble = add_bubble_icon ("input-keyboard-symbolic", _("Send Keys"), () => keys_menu (keys_bubble));
            display_bubbles.add (keys_bubble);
            fit_bubble = add_bubble_icon ("zoom-original-symbolic", _("Show at Original Size"), () => toggle_fit ());
            display_bubbles.add (fit_bubble);
            full_bubble = add_bubble_icon ("view-fullscreen-symbolic", _("Fullscreen"), () => toggle_fullscreen ());
            display_bubbles.add (full_bubble);
            details_bubble = add_bubble_icon ("document-properties-symbolic", _("Machine Details"), () => open_details ());
            display_bubbles.add (details_bubble);
            take_bubble = add_bubble_suggested (_("Take Snapshot"), () => snapshots.take ());

            notify["fullscreened"].connect (() => {
                full_bubble.icon_name = fullscreened ? "view-restore-symbolic" : "view-fullscreen-symbolic";
                full_bubble.tooltip_text = fullscreened ? _("Leave Fullscreen") : _("Fullscreen");
            });
            notify["is-active"].connect (() => {
                if (is_active) push_clipboard ();
                else screen_view.release_all ();
            });
            screen_view.get_clipboard ().changed.connect (() => {
                if (!screen_view.get_clipboard ().is_local ()) push_clipboard ();
            });

            add_window_action ("new", () => choose_source ());
            add_window_action ("close", () => close ());
            add_machine_action ("fullscreen", () => toggle_fullscreen ());
            add_machine_action ("pause", () => toggle_pause ());
            add_machine_action ("shutdown", () => run_power ("shutdown"));
            add_machine_action ("reset", () => run_power ("reset"));
            add_machine_action ("force-off", () => run_power ("force-off"));
            add_machine_action ("snapshot", () => quick_snapshot ());
            add_machine_action ("details", () => open_details ());
            add_machine_action ("send-ctrl-alt-del", () => {
                if (session != null) session.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.Delete });
            });
            fit_action = new SimpleAction.stateful ("fit", null, new Variant.boolean (true));
            fit_action.activate.connect (() => toggle_fit ());
            add_action (fit_action);
            machine_actions.add (fit_action);

            manager.store.changed.connect (rebuild);
            manager.state_changed.connect (on_state_changed);
            manager.thumbnail_changed.connect ((m) => {
                if (cards.has_key (m.id)) cards[m.id].reload ();
            });
            app.settings.changed["live-thumbnails"].connect (() => schedule_thumbnails ());
            close_request.connect (() => {
                end_session ();
                if (thumb_timer != 0) Source.remove (thumb_timer);
                thumb_timer = 0;
                if (!app.settings.get_boolean ("keep-running")) {
                    foreach (var m in manager.store.items) {
                        var c = manager.existing (m);
                        if (c != null && c.state.alive ()) c.shutdown.begin ();
                    }
                }
                return false;
            });
            rebuild ();
            schedule_thumbnails ();
            manager.load_osdb.begin ();
        }

        public delegate void Handler ();

        private void add_window_action (string name, owned Handler handler) {
            var a = new SimpleAction (name, null);
            a.activate.connect (() => handler ());
            add_action (a);
        }

        private void add_machine_action (string name, owned Handler handler) {
            var a = new SimpleAction (name, null);
            a.activate.connect (() => handler ());
            add_action (a);
            machine_actions.add (a);
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.machines";
            wp.title = _("Machines");
            wp.subtitle = _("Run other operating systems in a window. Start from an installation image or bring a disk image you already have.");
            wp.add_action ("media-optical", _("New Machine"), _("Install a system from an ISO image"), () => choose_source ());
            wp.add_action ("drive-harddisk", _("Import a Disk Image"), _("Use a QCOW2, raw, VMDK or VDI disk"), () => choose_source (true));
            return wp;
        }

        private Widget build_grid () {
            grid = new FlowBox ();
            grid.selection_mode = SelectionMode.NONE;
            grid.activate_on_single_click = true;
            grid.homogeneous = true;
            grid.min_children_per_line = 1;
            grid.max_children_per_line = 5;
            grid.column_spacing = 20;
            grid.row_spacing = 24;
            grid.valign = Align.START;
            grid.halign = Align.CENTER;
            grid.margin_top = 24;
            grid.margin_bottom = 32;
            grid.margin_start = 32;
            grid.margin_end = 32;
            grid.child_activated.connect ((child) => open_machine (((MachineCard) child).machine));
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = grid;
            apply_view_edge (scroll);
            return scroll;
        }

        private Widget build_display () {
            var overlay = new Overlay ();
            overlay.add_css_class ("machine-stage");
            screen_view = new RemoteDisplay ();
            screen_view.hexpand = true;
            screen_view.vexpand = true;
            display_scroll = new ScrolledWindow ();
            display_scroll.child = screen_view;
            display_scroll.hscrollbar_policy = PolicyType.NEVER;
            display_scroll.vscrollbar_policy = PolicyType.NEVER;
            overlay.child = display_scroll;

            status_box = new Box (Orientation.VERTICAL, 12);
            status_box.add_css_class ("machine-status");
            status_box.halign = Align.CENTER;
            status_box.valign = Align.CENTER;
            spinner = new Spinner ();
            spinner.set_size_request (32, 32);
            status_box.append (spinner);
            status_title = new Label ("");
            status_title.add_css_class ("title-3");
            status_title.wrap = true;
            status_title.justify = Justification.CENTER;
            status_box.append (status_title);
            status_detail = new Label ("");
            status_detail.add_css_class ("dim-label");
            status_detail.wrap = true;
            status_detail.max_width_chars = 48;
            status_detail.justify = Justification.CENTER;
            status_box.append (status_detail);
            var buttons = new Box (Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 8;
            status_back = new Button.with_label (_("Back"));
            status_back.add_css_class ("pill");
            status_back.clicked.connect (() => leave_display ());
            buttons.append (status_back);
            status_primary = new Button.with_label (_("Try Again"));
            status_primary.add_css_class ("pill");
            status_primary.add_css_class ("suggested-action");
            status_primary.clicked.connect (() => {
                if (current != null) open_machine (current);
            });
            buttons.append (status_primary);
            status_box.append (buttons);
            overlay.add_overlay (status_box);
            return overlay;
        }

        private void show_status (bool busy, string title, string detail, bool can_retry) {
            status_box.visible = true;
            spinner.spinning = busy;
            spinner.visible = busy;
            status_title.label = title;
            status_detail.label = detail;
            status_primary.visible = can_retry;
        }

        public void show_page (string name) {
            if (stack.visible_child_name == "display" && name != "display") save_display_thumbnail ();
            stack.visible_child_name = name;
            bool on_display = name == "display";
            add_bubble.visible = name == "grid";
            back_bubble.visible = name == "display" || name == "details" || name == "snapshots";
            take_bubble.visible = name == "snapshots" && current != null;
            var st = current != null ? manager.state_of (current) : MachineState.OFF;
            foreach (var w in display_bubbles) w.visible = on_display && current != null;
            pause_bubble.visible = on_display && st.alive ();
            power_bubble.visible = on_display && st.alive ();
            keys_bubble.visible = on_display && session != null && session.active;
            fit_bubble.visible = on_display && session != null && session.active;
            foreach (var a in machine_actions) a.set_enabled (current != null && st.alive () && on_display);
            ((SimpleAction) lookup_action ("details")).set_enabled (current != null);
            sync_pause ();
            if (name == "details" && current != null) details.show_machine (current);
            if (name == "snapshots" && current != null) snapshots.show_machine (current);
            if (name == "grid") schedule_thumbnails ();
            if (!on_display) inhibit_shortcuts (false);
        }

        private void go_back () {
            string page = stack.visible_child_name;
            if (page == "snapshots") {
                show_page ("details");
            } else if (page == "details") {
                if (current != null && manager.state_of (current).alive ()) {
                    show_page ("display");
                    if (session == null) connect_display ();
                } else {
                    leave_display ();
                }
            } else {
                leave_display ();
            }
        }

        private void rebuild () {
            Widget? child;
            while ((child = grid.get_first_child ()) != null) grid.remove (child);
            cards.clear ();
            foreach (var m in manager.store.items) {
                var card = new MachineCard (m);
                card.update (manager.state_of (m));
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => card_menu (card, x, y));
                card.add_controller (click);
                var press = new GestureLongPress ();
                press.pressed.connect ((x, y) => card_menu (card, x, y));
                card.add_controller (press);
                cards[m.id] = card;
                grid.append (card);
            }
            string page = stack.visible_child_name;
            if (page == "welcome" || page == "grid" || page == null) show_page (manager.store.items.size == 0 ? "welcome" : "grid");
            if (current != null && !manager.store.items.contains (current)) {
                current = null;
                if (page != "welcome" && page != "grid") show_page (manager.store.items.size == 0 ? "welcome" : "grid");
            }
        }

        private void on_state_changed (Machine m) {
            var st = manager.state_of (m);
            if (cards.has_key (m.id)) cards[m.id].update (st);
            if (m != current) return;
            string page = stack.visible_child_name;
            if (page == "display") {
                if (st == MachineState.OFF) {
                    end_session ();
                    if (fullscreened) unfullscreen ();
                    add_toast (new Toast (_("%s is off").printf (m.title ())));
                    show_page (manager.store.items.size == 0 ? "welcome" : "grid");
                    return;
                }
                show_page ("display");
            } else if (page == "details") {
                details.show_machine (m);
            } else if (page == "snapshots") {
                snapshots.show_machine (m);
            }
            sync_pause ();
        }

        private void sync_pause () {
            if (current == null) return;
            bool paused = manager.state_of (current) == MachineState.PAUSED;
            pause_bubble.icon_name = paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
            pause_bubble.tooltip_text = paused ? _("Resume") : _("Pause");
        }

        private void schedule_thumbnails () {
            if (thumb_timer != 0) return;
            thumb_timer = Timeout.add_seconds (4, () => {
                if (!app.settings.get_boolean ("live-thumbnails") || stack.visible_child_name != "grid") {
                    thumb_timer = 0;
                    return Source.REMOVE;
                }
                foreach (var m in manager.store.items) manager.refresh_thumbnail.begin (m);
                return Source.CONTINUE;
            });
            foreach (var m in manager.store.items) manager.refresh_thumbnail.begin (m);
        }

        private void card_menu (MachineCard card, double x, double y) {
            var m = card.machine;
            var st = manager.state_of (m);
            var menu = new ContextMenu (card);
            menu.add_item (st.alive () ? _("Open") : _("Start"), "media-playback-start-symbolic", () => open_machine (m));
            if (st == MachineState.RUNNING) menu.add_item (_("Pause"), "media-playback-pause-symbolic", () => control (m, "pause"));
            if (st == MachineState.PAUSED) menu.add_item (_("Resume"), "media-playback-start-symbolic", () => control (m, "resume"));
            if (st.alive ()) {
                menu.add_item (_("Shut Down"), "system-shutdown-symbolic", () => control (m, "shutdown"));
                menu.add_item (_("Force Off"), "process-stop-symbolic", () => control (m, "force-off"));
            }
            menu.add_item (_("Details"), "document-properties-symbolic", () => {
                current = m;
                open_details ();
            });
            menu.add_separator ();
            menu.add_item (_("Delete"), "user-trash-symbolic", () => confirm_delete (m), "destructive");
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        public void report (string title, Error e) {
            var dlg = new ConfirmDialog.message ((Gtk.Application) application, title, "dialog-error", e.message);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.present ();
        }

        public void control (Machine m, string what) {
            var c = manager.controller (m);
            if (what == "shutdown" || what == "force-off") manager.refresh_thumbnail.begin (m);
            control_async.begin (c, what, (o, res) => {
                try {
                    control_async.end (res);
                } catch (Error e) {
                    report (_("Could Not Change %s").printf (m.title ()), e);
                }
            });
        }

        private async void control_async (MachineController c, string what) throws Error {
            switch (what) {
                case "pause": yield c.pause (); break;
                case "resume": yield c.resume (); break;
                case "shutdown": yield c.shutdown (); break;
                case "force-off": yield c.force_off (); break;
                case "reset": yield c.reset (); break;
            }
        }

        private void run_power (string what) {
            if (current != null) control (current, what);
        }

        private void toggle_pause () {
            if (current == null) return;
            var st = manager.state_of (current);
            if (st == MachineState.PAUSED) control (current, "resume");
            else if (st == MachineState.RUNNING) control (current, "pause");
        }

        private void power_menu (Button anchor) {
            if (current == null) return;
            var m = current;
            var menu = new ContextMenu (anchor);
            menu.add_item (_("Shut Down"), "system-shutdown-symbolic", () => control (m, "shutdown"));
            menu.add_item (_("Restart"), "view-refresh-symbolic", () => control (m, "reset"));
            menu.add_separator ();
            menu.add_item (_("Force Off"), "process-stop-symbolic", () => control (m, "force-off"), "destructive");
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void keys_menu (Button anchor) {
            if (session == null) return;
            var s = session;
            var menu = new ContextMenu (anchor);
            menu.add_item ("Ctrl+Alt+Del", null, () => s.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.Delete }));
            menu.add_item ("Ctrl+Alt+Backspace", null, () => s.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, Gdk.Key.BackSpace }));
            for (int i = 1; i <= 3; i++) {
                uint key = Gdk.Key.F1 + i - 1;
                menu.add_item ("Ctrl+Alt+F%d".printf (i), null, () => s.send_combo ({ Gdk.Key.Control_L, Gdk.Key.Alt_L, key }));
            }
            menu.add_item (_("Super"), null, () => s.send_combo ({ Gdk.Key.Super_L }));
            menu.add_item (_("Print Screen"), null, () => s.send_combo ({ Gdk.Key.Print }));
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void toggle_fit () {
            screen_view.fit = !screen_view.fit;
            fit_action.set_state (new Variant.boolean (screen_view.fit));
            fit_bubble.icon_name = screen_view.fit ? "zoom-original-symbolic" : "zoom-fit-best-symbolic";
            fit_bubble.tooltip_text = screen_view.fit ? _("Show at Original Size") : _("Fit to Window");
            display_scroll.hscrollbar_policy = screen_view.fit ? PolicyType.NEVER : PolicyType.AUTOMATIC;
            display_scroll.vscrollbar_policy = screen_view.fit ? PolicyType.NEVER : PolicyType.AUTOMATIC;
        }

        private void toggle_fullscreen () {
            if (fullscreened) unfullscreen ();
            else if (stack.visible_child_name == "display") fullscreen ();
        }

        private void open_details () {
            if (current == null) return;
            show_page ("details");
        }

        public void open_machine (Machine m) {
            if (session != null && current != m) end_session ();
            current = m;
            var c = manager.controller (m);
            show_page ("display");
            screen_view.fit = true;
            screen_view.resize_remote = m.resize_guest;
            if (c.state.alive ()) {
                if (c.state == MachineState.PAUSED) control (m, "resume");
                if (session == null) connect_display ();
                return;
            }
            show_status (true, _("Starting %s").printf (m.title ()), m.os_name, false);
            c.start.begin (null, (o, res) => {
                try {
                    c.start.end (res);
                    manager.store.put (m);
                    if (current == m && stack.visible_child_name == "display") connect_display ();
                } catch (Error e) {
                    if (current == m) show_status (false, _("Could Not Start"), e.message, true);
                }
            });
        }

        private void connect_display () {
            if (current == null) return;
            var m = current;
            var c = manager.controller (m);
            var address = c.display_address ();
            if (address == null) {
                show_status (false, _("%s is off").printf (m.title ()), "", true);
                return;
            }
            end_session ();
            show_status (true, _("Connecting to %s").printf (m.title ()), "", false);
            var s = new VncSession.with_address (address, m.title ());
            session = s;
            s.ready.connect (() => {
                if (session != s) return;
                connect_attempt = 0;
                status_box.visible = false;
                screen_view.session = s;
                screen_view.resize_remote = m.resize_guest;
                show_page ("display");
                screen_view.grab_focus ();
                inhibit_shortcuts (true);
                push_clipboard ();
            });
            s.remote_clipboard.connect ((text) => {
                last_clipboard = text;
                screen_view.get_clipboard ().set_text (text);
            });
            s.bell.connect (() => screen_view.error_bell ());
            s.closed.connect ((err) => {
                if (session != s) return;
                session = null;
                screen_view.session = null;
                inhibit_shortcuts (false);
                if (current != m || stack.visible_child_name != "display") return;
                if (manager.state_of (m).alive () && connect_attempt < 20) {
                    connect_attempt++;
                    Timeout.add (250, () => {
                        if (current == m && session == null && stack.visible_child_name == "display") connect_display ();
                        return Source.REMOVE;
                    });
                    return;
                }
                if (!manager.state_of (m).alive ()) return;
                show_status (false, _("The Display Is Not Available"), err != null ? err.message : "", true);
            });
            s.start ();
        }

        private void end_session () {
            var s = session;
            session = null;
            inhibit_shortcuts (false);
            if (s == null) return;
            save_display_thumbnail ();
            screen_view.release_all ();
            screen_view.session = null;
            s.stop ();
        }

        private void save_display_thumbnail () {
            if (current == null || session == null || session.texture == null) return;
            if (session.texture.save_to_png (current.screenshot_path ()) && cards.has_key (current.id)) cards[current.id].reload ();
        }

        private void leave_display () {
            end_session ();
            if (fullscreened) unfullscreen ();
            show_page (manager.store.items.size == 0 ? "welcome" : "grid");
        }

        private void inhibit_shortcuts (bool on) {
            var toplevel = get_surface () as Gdk.Toplevel;
            if (toplevel == null || on == inhibiting) return;
            inhibiting = on;
            if (on) toplevel.inhibit_system_shortcuts (null);
            else toplevel.restore_system_shortcuts ();
        }

        private void push_clipboard () {
            if (session == null || !session.active) return;
            var s = session;
            screen_view.get_clipboard ().read_text_async.begin (null, (o, res) => {
                try {
                    string? text = screen_view.get_clipboard ().read_text_async.end (res);
                    if (text == null || text == last_clipboard || session != s) return;
                    last_clipboard = text;
                    s.send_clipboard (text);
                } catch (Error e) {
                }
            });
        }

        private void quick_snapshot () {
            if (current == null) return;
            snapshots.show_machine (current);
            snapshots.take ();
        }

        public void confirm_delete (Machine m) {
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("Delete %s?").printf (m.title ()), "user-trash-full",
                _("The machine, its disk and its snapshots are removed. This cannot be undone."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                delete_machine.begin (m);
            });
            dlg.present ();
        }

        private async void delete_machine (Machine m) {
            var c = manager.controller (m);
            if (current == m) {
                end_session ();
                current = null;
            }
            if (c.state.alive ()) {
                try {
                    yield c.force_off ();
                } catch (Error e) {
                }
                for (int i = 0; i < 40 && c.state.alive (); i++) yield Tool.sleep (100);
            }
            try {
                yield manager.backend_for (m).destroy (m);
            } catch (Error e) {
                warning ("machines: %s", e.message);
            }
            manager.forget (m);
            manager.store.remove (m);
            show_page (manager.store.items.size == 0 ? "welcome" : "grid");
        }

        public void choose_source (bool disk = false) {
            var dialog = new FileDialog ();
            dialog.title = disk ? _("Import a Disk Image") : _("Choose an Installation Image");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var f = new FileFilter ();
            f.name = disk ? _("Disk Images") : _("Installation and Disk Images");
            if (!disk) {
                f.add_suffix ("iso");
                f.add_mime_type ("application/x-cd-image");
            }
            foreach (string s in new string[] { "qcow2", "img", "raw", "vmdk", "vdi", "vhd", "vhdx" }) f.add_suffix (s);
            filters.append (f);
            var all = new FileFilter ();
            all.name = _("All Files");
            all.add_pattern ("*");
            filters.append (all);
            dialog.filters = filters;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    var file = dialog.open.end (res);
                    if (file != null && file.get_path () != null) create_from.begin (file.get_path ());
                } catch (Error e) {
                }
            });
        }

        public async void create_from (string path) {
            if (!manager.backend.available ()) {
                report (_("Machines Cannot Run Here"), new IOError.NOT_SUPPORTED (manager.backend.unavailable_reason ()));
                return;
            }
            yield manager.load_osdb ();
            var detection = Detector.detect (path, manager.osdb, manager.host.arch, manager.limits);
            var dlg = new NewMachineDialog (app, manager, path, detection);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.change_source.connect (() => choose_source (detection.is_disk_image));
            dlg.created.connect ((m) => prepare_and_start.begin (m));
            dlg.present ();
        }

        private async void prepare_and_start (Machine m) {
            current = m;
            var c = manager.controller (m);
            show_page ("display");
            show_status (true, m.source_image != "" ? _("Importing the Disk") : _("Creating %s").printf (m.title ()), m.os_name, false);
            try {
                yield manager.backend_for (m).prepare (m, null);
            } catch (Error e) {
                if (current == m) show_status (false, _("Could Not Create the Machine"), e.message, false);
                return;
            }
            if (c.state == MachineState.OFF) open_machine (m);
        }
    }
}

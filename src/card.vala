using Gtk;

namespace Singularity.Apps.Machines {

    public class Thumbnail : Widget {
        private Gdk.Texture? texture;
        public int thumb_width { get; construct; }
        public int thumb_height { get; construct; }

        public Thumbnail (int w, int h) {
            Object (thumb_width: w, thumb_height: h);
        }

        public bool load (string path) {
            try {
                texture = FileUtils.test (path, FileTest.IS_REGULAR) ? Gdk.Texture.from_filename (path) : null;
            } catch (Error e) {
                texture = null;
            }
            queue_draw ();
            return texture != null;
        }

        protected override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum = natural = orientation == Orientation.HORIZONTAL ? thumb_width : thumb_height;
            minimum_baseline = natural_baseline = -1;
        }

        protected override void snapshot (Gtk.Snapshot snapshot) {
            if (texture == null) return;
            double w = get_width (), h = get_height ();
            double scale = double.max (w / texture.width, h / texture.height);
            double dw = texture.width * scale, dh = texture.height * scale;
            var rect = Graphene.Rect ().init ((float) ((w - dw) / 2), (float) ((h - dh) / 2), (float) dw, (float) dh);
            snapshot.append_scaled_texture (texture, Gsk.ScalingFilter.TRILINEAR, rect);
        }
    }

    public class MachineCard : FlowBoxChild {
        public Machine machine { get; construct; }
        private Overlay thumb;
        private Thumbnail picture;
        private Image placeholder;
        private Label badge;
        private Label caption;

        public MachineCard (Machine m) {
            Object (machine: m);
            add_css_class ("machine-card");
            var box = new Box (Orientation.VERTICAL, 8);

            thumb = new Overlay ();
            thumb.add_css_class ("machine-thumb");
            thumb.overflow = Overflow.HIDDEN;
            thumb.set_size_request (232, 145);
            picture = new Thumbnail (232, 145);
            picture.add_css_class ("machine-picture");
            thumb.child = picture;
            placeholder = new Image.from_icon_name ("dev.sinty.machines");
            placeholder.pixel_size = 64;
            placeholder.halign = Align.CENTER;
            placeholder.valign = Align.CENTER;
            thumb.add_overlay (placeholder);
            badge = new Label ("");
            badge.add_css_class ("machine-badge");
            badge.halign = Align.START;
            badge.valign = Align.END;
            badge.margin_start = 10;
            badge.margin_bottom = 10;
            thumb.add_overlay (badge);
            box.append (thumb);

            var name = new Label (m.title ());
            name.add_css_class ("machine-name");
            name.halign = Align.START;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 24;
            box.append (name);
            caption = new Label ("");
            caption.add_css_class ("dim-label");
            caption.add_css_class ("caption");
            caption.halign = Align.START;
            caption.ellipsize = Pango.EllipsizeMode.END;
            caption.max_width_chars = 28;
            box.append (caption);
            child = box;
            reload ();
            update (MachineState.OFF);
        }

        public void reload () {
            placeholder.visible = !picture.load (machine.screenshot_path ());
        }

        private string resources () {
            string mem = machine.memory_mib % 1024 == 0 ? _("%d GiB").printf (machine.memory_mib / 1024) : _("%.1f GiB").printf (machine.memory_mib / 1024.0);
            return "%s, %s".printf (mem, ngettext ("%d processor", "%d processors", machine.cpus).printf (machine.cpus));
        }

        public void update (MachineState state) {
            badge.label = state.label ();
            badge.remove_css_class ("running");
            badge.remove_css_class ("paused");
            if (state == MachineState.RUNNING) badge.add_css_class ("running");
            else if (state == MachineState.PAUSED) badge.add_css_class ("paused");
            if (state.alive ()) thumb.remove_css_class ("off");
            else thumb.add_css_class ("off");
            string os = machine.os_name != "" ? machine.os_name : _("Unknown system");
            caption.label = machine.os_name != "" && machine.os_name != machine.title () ? os : resources ();
            update_property (AccessibleProperty.DESCRIPTION, "%s, %s".printf (os, state.label ()), -1);
        }
    }
}

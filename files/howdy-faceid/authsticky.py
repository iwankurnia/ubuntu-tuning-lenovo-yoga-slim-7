# Face ID-style authentication popup for Howdy (replaces howdy-gtk's authsticky.py).
#
# Howdy's compare.py starts this with `howdy-gtk --start-auth-ui` and writes lines to
# its stdin: "M=<message>" and "S=<subtext>". The kit's "faceid" rubberstamp sends
# "M=_SUCCESS" once the face is recognised, which turns the glyph into a tick.
# compare.py terminates this process when authentication ends.
import math
import os
import signal
import sys
import time

# Prefer X11 (XWayland), as Wayland does not let a window place itself at the top.
os.environ.setdefault("GDK_BACKEND", "x11,*")

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, GLib, Gtk, Pango, PangoCairo  # noqa: E402

SIZE = 168          # the popup is a square, like the iOS Face ID HUD
RADIUS = 34
TOP_MARGIN = 14     # gap below the top of the screen, under the camera
GLYPH = 74          # size of the Face ID glyph
STROKE = 4.2
FADE_IN = 0.16      # seconds
TICK_TIME = 0.32    # seconds to draw the tick


def ease_out(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


class FaceIdWindow(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="Face ID")
        self.state = "scanning"
        self.started = time.monotonic()
        self.success_at = None
        self.subtext = ""

        self.stick()
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_app_paintable(True)
        self.set_skip_pager_hint(True)
        self.set_skip_taskbar_hint(True)
        self.set_can_focus(False)
        self.set_accept_focus(False)
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.set_decorated(False)

        screen = Gdk.Screen.get_default()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        area = Gtk.DrawingArea()
        area.set_size_request(SIZE, SIZE)
        area.connect("draw", self.draw)
        self.add(area)
        self.area = area

        self.connect("destroy", Gtk.main_quit)
        self.connect("button-press-event", lambda *a: Gtk.main_quit())

        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        geo = monitor.get_geometry()
        self.move(geo.x + (geo.width - SIZE) // 2, geo.y + TOP_MARGIN)

        Gtk.Widget.set_opacity(self, 0.0)
        self.show_all()

        GLib.io_add_watch(sys.stdin.fileno(), GLib.PRIORITY_DEFAULT,
                          GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.on_input)
        GLib.timeout_add(16, self.tick)

    # -- input from compare.py
    def on_input(self, fd, condition):
        if condition & (GLib.IO_HUP | GLib.IO_ERR):
            line = sys.stdin.readline()
            if not line:
                self.finish()
                return False
        else:
            line = sys.stdin.readline()
            if not line:
                self.finish()
                return False
        line = line.rstrip("\n").strip()
        if line.startswith("M="):
            if line[2:].strip() == "_SUCCESS" and self.state != "success":
                self.state = "success"
                self.success_at = time.monotonic()
        elif line.startswith("S="):
            self.subtext = line[2:].strip()
        return True

    def finish(self):
        # pipe closed: leave a finished tick on screen for a moment, otherwise go now
        if self.state == "success":
            GLib.timeout_add(250, Gtk.main_quit)
        else:
            Gtk.main_quit()

    # -- animation clock
    def tick(self):
        age = time.monotonic() - self.started
        Gtk.Widget.set_opacity(self, ease_out(age / FADE_IN))
        self.area.queue_draw()
        return True

    # -- drawing
    def draw(self, widget, ctx):
        ctx.set_operator(cairo.OPERATOR_SOURCE)
        ctx.set_source_rgba(0, 0, 0, 0)
        ctx.paint()
        ctx.set_operator(cairo.OPERATOR_OVER)

        # the rounded HUD
        self.rounded_rect(ctx, 0.5, 0.5, SIZE - 1, SIZE - 1, RADIUS)
        ctx.set_source_rgba(0.11, 0.11, 0.12, 0.93)
        ctx.fill_preserve()
        ctx.set_source_rgba(1, 1, 1, 0.09)
        ctx.set_line_width(1)
        ctx.stroke()

        now = time.monotonic()
        cx, cy = SIZE / 2, SIZE / 2 - 12
        if self.state == "success":
            t = (now - self.success_at) / TICK_TIME
            self.draw_glyph(ctx, cx, cy, 1.0 - ease_out(t * 1.6), features=True, pulse=0)
            self.draw_tick(ctx, cx, cy, ease_out(t))
            label = "Recognised"
        else:
            # iOS-style idle pulse while scanning
            pulse = 0.5 + 0.5 * math.sin((now - self.started) * 5.0)
            self.draw_glyph(ctx, cx, cy, 1.0, features=True, pulse=pulse)
            label = "Face ID"
        self.draw_label(ctx, label, SIZE / 2, SIZE - 38)

    @staticmethod
    def rounded_rect(ctx, x, y, w, h, r):
        ctx.new_sub_path()
        ctx.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        ctx.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        ctx.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        ctx.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        ctx.close_path()

    def draw_glyph(self, ctx, cx, cy, alpha, features, pulse):
        if alpha <= 0.01:
            return
        g = GLYPH
        half = g / 2
        # corner brackets breathe slightly outwards while scanning
        spread = 1.0 + 0.045 * pulse
        arm = g * 0.24
        r = g * 0.13
        ctx.save()
        ctx.translate(cx, cy)
        ctx.scale(spread, spread)
        ctx.set_line_width(STROKE / spread)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        ctx.set_source_rgba(1, 1, 1, alpha)
        for quarter in range(4):
            # the top-left bracket, turned a quarter at a time
            ctx.save()
            ctx.rotate(quarter * math.pi / 2)
            ctx.move_to(-half, -half + arm)
            ctx.line_to(-half, -half + r)
            ctx.arc(-half + r, -half + r, r, math.pi, 1.5 * math.pi)
            ctx.line_to(-half + arm, -half)
            ctx.restore()
        ctx.stroke()
        ctx.restore()

        if not features:
            return
        ctx.save()
        ctx.translate(cx, cy)
        ctx.set_line_width(STROKE)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        ctx.set_source_rgba(1, 1, 1, alpha * (0.78 + 0.22 * pulse))
        eye_y0, eye_y1 = -g * 0.17, -g * 0.05
        for ex in (-g * 0.17, g * 0.17):
            ctx.move_to(ex, eye_y0)
            ctx.line_to(ex, eye_y1)
        # nose
        ctx.move_to(g * 0.01, -g * 0.15)
        ctx.line_to(g * 0.01, g * 0.06)
        ctx.line_to(-g * 0.06, g * 0.06)
        # smile
        ctx.move_to(-g * 0.17, g * 0.17)
        ctx.curve_to(-g * 0.08, g * 0.27, g * 0.08, g * 0.27, g * 0.17, g * 0.17)
        ctx.stroke()
        ctx.restore()

    def draw_tick(self, ctx, cx, cy, t):
        if t <= 0:
            return
        g = GLYPH
        pts = [(-g * 0.30, g * 0.02), (-g * 0.08, g * 0.24), (g * 0.32, -g * 0.22)]
        seg1 = math.dist(pts[0], pts[1])
        seg2 = math.dist(pts[1], pts[2])
        length = (seg1 + seg2) * t
        ctx.save()
        ctx.translate(cx, cy)
        ctx.set_line_width(STROKE * 1.5)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        ctx.set_source_rgba(1, 1, 1, 1)
        ctx.move_to(*pts[0])
        if length <= seg1:
            f = length / seg1
            ctx.line_to(pts[0][0] + (pts[1][0] - pts[0][0]) * f, pts[0][1] + (pts[1][1] - pts[0][1]) * f)
        else:
            ctx.line_to(*pts[1])
            f = (length - seg1) / seg2
            ctx.line_to(pts[1][0] + (pts[2][0] - pts[1][0]) * f, pts[1][1] + (pts[2][1] - pts[1][1]) * f)
        ctx.stroke()
        ctx.restore()

    def draw_label(self, ctx, text, cx, cy):
        layout = PangoCairo.create_layout(ctx)
        layout.set_font_description(Pango.FontDescription.from_string("Ubuntu Sans Medium 11.5"))
        layout.set_text(text, -1)
        w, h = layout.get_pixel_size()
        ctx.move_to(cx - w / 2, cy - h / 2)
        ctx.set_source_rgba(1, 1, 1, 0.92)
        PangoCairo.show_layout(ctx, layout)


def render_png(path, state, t):
    """Draw one frame into a PNG (for previews and tests); no window is opened."""
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, SIZE * 2, SIZE * 2)
    ctx = cairo.Context(surface)
    ctx.scale(2, 2)
    fake = FaceIdWindow.__new__(FaceIdWindow)
    now = time.monotonic()
    fake.state = state
    fake.started = now - t
    fake.success_at = now - t if state == "success" else None
    FaceIdWindow.draw(fake, None, ctx)
    surface.write_to_png(path)


if os.environ.get("FACEID_RENDER"):
    for spec in os.environ["FACEID_RENDER"].split(","):
        state, t, out = spec.split(":")
        render_png(out, state, float(t))
else:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    FaceIdWindow()
    Gtk.main()

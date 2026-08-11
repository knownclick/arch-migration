-- Hardware-portable Hyprland session used only to host ReGreet.
-- Unlike the old machine's file, this does not assume HDMI-A-1 exists.
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = 1,
})

hl.env("GTK_USE_PORTAL", "0")
hl.env("GDK_DEBUG", "no-portals")
hl.env("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
hl.env("XCURSOR_SIZE", "24")

hl.on("hyprland.start", function()
    hl.exec_cmd([[regreet; hyprctl dispatch 'hl.dsp.exit()']])
end)

hl.config({
    general = {
        gaps_in = 0,
        gaps_out = 0,
        border_size = 0,
    },
    decoration = {
        rounding = 0,
        shadow = { enabled = false },
        blur = { enabled = false },
    },
    animations = { enabled = true },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        disable_hyprland_guiutils_check = true,
        background_color = 0x00141d,
    },
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        touchpad = { natural_scroll = false },
    },
})

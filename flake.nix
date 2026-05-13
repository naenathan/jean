{
  description = "Jean (coollabsio) build environment for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # JS toolchain
            nodejs_22
            bun

            # Rust toolchain (Tauri backend)
            rustc
            cargo
            rustfmt
            clippy
            pkg-config

            # Tauri v2 system deps
            webkitgtk_4_1
            libsoup_3
            gtk3
            glib
            cairo
            pango
            atk
            gdk-pixbuf
            librsvg
            libayatana-appindicator
            openssl

            # GStreamer (WebKitGTK uses it for media; missing plugins
            # cause GLib-GObject CRITICAL errors and an unresponsive webview)
            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
            gst_all_1.gst-plugins-bad

            # GSettings schemas (gtk3 file-chooser, font config, etc.)
            gsettings-desktop-schemas

            # Misc runtime
            xdg-utils
            git
          ];

          # Tauri / webkit need these to find libs at runtime
          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.webkitgtk_4_1.dev}/lib/pkgconfig:${pkgs.libsoup_3.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [
              pkgs.webkitgtk_4_1
              pkgs.libsoup_3
              pkgs.gtk3
              pkgs.libayatana-appindicator
            ]}:$LD_LIBRARY_PATH"
            export GST_PLUGIN_SYSTEM_PATH_1_0="${pkgs.gst_all_1.gstreamer.out}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-good}/lib/gstreamer-1.0:${pkgs.gst_all_1.gst-plugins-bad}/lib/gstreamer-1.0''${GST_PLUGIN_SYSTEM_PATH_1_0:+:$GST_PLUGIN_SYSTEM_PATH_1_0}"
            # GLib looks here for compiled schemas at runtime — gtk3 ships its
            # FileChooser schema this way, and GNOME's session only exposes gtk4 schemas.
            export GSETTINGS_SCHEMA_DIR="${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}/glib-2.0/schemas:${pkgs.glib}/share/gsettings-schemas/${pkgs.glib.name}/glib-2.0/schemas:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas''${GSETTINGS_SCHEMA_DIR:+:$GSETTINGS_SCHEMA_DIR}"
            # Some Wayland setups need this to render correctly under WebKit
            export WEBKIT_DISABLE_COMPOSITING_MODE=1
            echo "Jean dev shell ready."
          '';
        };
      });
}
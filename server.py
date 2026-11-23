#!/usr/bin/env python3
"""Leaf OS ISO edition: serves the desktop on http://127.0.0.1:8080 and handles
the Start menu's Shut down / Reboot buttons."""
import functools
import http.server
import subprocess

ROOT = "/opt/leafos"


class LeafHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        # The custom header blocks requests coming from other websites
        if self.headers.get("X-Leaf") == "1" and self.path in ("/power/off", "/power/reboot"):
            self.send_response(204)
            self.end_headers()
            action = "poweroff" if self.path.endswith("off") else "reboot"
            subprocess.Popen(["sudo", "-n", "systemctl", action])
        else:
            self.send_response(403)
            self.end_headers()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    handler = functools.partial(LeafHandler, directory=ROOT)
    http.server.ThreadingHTTPServer(("127.0.0.1", 8080), handler).serve_forever()

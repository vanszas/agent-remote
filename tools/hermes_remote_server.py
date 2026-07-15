import json
import socket
import subprocess
import sys
import time
import urllib.request

PORT = 9119
HOST = "127.0.0.1"
TAILNET_URL = "https://pc-ivan-rtx5060ti.tailbdc657.ts.net"
HERMES = r"C:\Users\ADMIN\AppData\Local\hermes\hermes-agent\venv\Scripts\hermes.exe"
TAILSCALE = r"C:\Program Files\Tailscale\tailscale.exe"


def port_open():
    with socket.socket() as sock:
        sock.settimeout(1)
        return sock.connect_ex((HOST, PORT)) == 0


def wait_port():
    for _ in range(60):
        if port_open():
            return
        time.sleep(1)
    raise RuntimeError("Hermes backend did not open port 9119")


def run(*args):
    return subprocess.run(args, text=True, capture_output=True)


def configure_serve():
    error = "Tailscale is unavailable"
    for _ in range(12):
        result = run(TAILSCALE, "serve", "--bg", f"http://{HOST}:{PORT}")
        if result.returncode == 0:
            return
        error = result.stderr.strip() or result.stdout.strip() or error
        time.sleep(5)
    raise RuntimeError(error)


def verify_https():
    with urllib.request.urlopen(f"{TAILNET_URL}/api/status", timeout=20) as response:
        if response.status != 200:
            raise RuntimeError(f"HTTPS health check returned {response.status}")
        json.load(response)


def main():
    backend = None
    if port_open():
        print("Hermes backend already running on port 9119.")
    else:
        print("Starting Hermes backend...")
        backend = subprocess.Popen(
            [HERMES, "--profile", "vans", "serve", "--host", "0.0.0.0", "--port", str(PORT), "--skip-build"],
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
        )
        wait_port()

    print("Configuring Tailscale Serve...")
    configure_serve()
    verify_https()
    print(f"Ready: {TAILNET_URL}")
    print("Keep this window open. Press Ctrl+C to stop.")
    try:
        while backend is None or backend.poll() is None:
            time.sleep(2)
    except KeyboardInterrupt:
        print("Stopping...")
    finally:
        if backend is not None and backend.poll() is None:
            backend.terminate()
            try:
                backend.wait(timeout=8)
            except subprocess.TimeoutExpired:
                backend.kill()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}")
        input("Press Enter to close...")
        sys.exit(1)

# ponytail: foreground launcher only; add Windows service mode when unattended startup is requested.

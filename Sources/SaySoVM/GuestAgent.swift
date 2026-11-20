import CryptoKit
import Foundation

/// Lo que se instala dentro de la VM en el primer arranque: el agente invitado (Python, ya
/// incluido en la imagen de Debian) y la configuración de cloud-init que lo deja como servicio.
public enum GuestAgent {
    /// Usuario sin privilegios con el que trabaja el agente. Tiene sudo dentro de la VM.
    public static let user = "agent"

    /// Servicio que atiende al host por vsock.
    public static let script = #"""
    #!/usr/bin/env python3
    # Agente invitado de SaySo: atiende ordenes del host por vsock.
    import base64, json, os, signal, socket, struct, subprocess, threading, time

    PORT = 7300
    HOME = os.path.expanduser("~")
    WORK = os.path.join(HOME, "sayso")
    OLD_WORK = os.path.join(HOME, "work")
    LIMIT = 200000
    MAX_FRAME = 64 * 1024 * 1024
    MAX_FILE = 8 * 1024 * 1024


    def recv_exact(conn, n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                raise EOFError()
            buf += chunk
        return buf


    def read_frame(conn):
        (n,) = struct.unpack(">I", recv_exact(conn, 4))
        if n > MAX_FRAME:
            raise ValueError("frame too large")
        return json.loads(recv_exact(conn, n))


    def send_frame(conn, obj):
        data = json.dumps(obj).encode()
        conn.sendall(struct.pack(">I", len(data)) + data)


    def clip(raw):
        text = raw.decode("utf-8", "replace")
        if len(text) > LIMIT:
            half = LIMIT // 2
            text = text[:half] + "\n[... salida recortada ...]\n" + text[-half:]
        return text


    def resolve(path):
        path = os.path.expanduser(path or "")
        if not os.path.isabs(path):
            path = os.path.join(WORK, path)
        return os.path.normpath(path)


    def child_env(req):
        env = dict(os.environ)
        for key, value in (req.get("env") or {}).items():
            env[str(key)] = str(value)
        return env


    def do_spawn(conn, req):
        # Proceso que sigue vivo: tras responder, la conexion pasa a ser su entrada y su salida.
        cwd = resolve(req.get("cwd") or WORK)
        log = open(os.path.join(HOME, ".sayso-spawn.log"), "ab")
        proc = subprocess.Popen(["/bin/bash", "-lc", req["command"]], cwd=cwd, env=child_env(req),
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                start_new_session=True)
        send_frame(conn, {"ok": True})

        def pump_out():
            try:
                while True:
                    chunk = proc.stdout.read1(65536)
                    if not chunk:
                        break
                    conn.sendall(chunk)
            except OSError:
                pass
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        threading.Thread(target=pump_out, daemon=True).start()
        try:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                proc.stdin.write(chunk)
                proc.stdin.flush()
        except (OSError, ValueError):
            pass
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        log.close()


    def do_exec(req):
        timeout = max(1.0, min(float(req.get("timeout") or 120), 3600.0))
        cwd = resolve(req.get("cwd") or WORK)
        if not os.path.isdir(cwd):
            return {"ok": False, "error": "No existe el directorio " + cwd}
        proc = subprocess.Popen(["/bin/bash", "-lc", req["command"]], cwd=cwd, env=child_env(req),
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, err = proc.communicate()
        return {"ok": True, "exit": proc.returncode, "stdout": clip(out), "stderr": clip(err),
                "timed_out": timed_out}


    def do_read(req):
        path = resolve(req["path"])
        if os.path.getsize(path) > MAX_FILE:
            return {"ok": False, "error": "El archivo supera 8 MB"}
        with open(path, "rb") as f:
            return {"ok": True, "data": base64.b64encode(f.read()).decode()}


    def do_write(req):
        path = resolve(req["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(base64.b64decode(req["data"]))
        return {"ok": True}


    def cpu_times():
        with open("/proc/stat") as f:
            vals = [int(v) for v in f.readline().split()[1:]]
        return sum(vals), vals[3] + vals[4]


    def do_stats(_req):
        t1, i1 = cpu_times()
        time.sleep(0.2)
        t2, i2 = cpu_times()
        cpu = 100.0 * (1.0 - (i2 - i1) / max(t2 - t1, 1))
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, value = line.split(":", 1)
                mem[key] = int(value.split()[0]) * 1024
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        return {"ok": True, "cpu": max(0.0, cpu), "cpus": os.cpu_count() or 1,
                "mem_total": mem["MemTotal"], "mem_used": mem["MemTotal"] - mem["MemAvailable"],
                "disk_total": total, "disk_used": total - st.f_bfree * st.f_frsize}


    def do_poweroff(_req):
        subprocess.Popen(["sudo", "systemctl", "poweroff"])
        return {"ok": True}


    OPS = {"ping": lambda _r: {"ok": True}, "exec": do_exec, "read": do_read, "write": do_write,
           "stats": do_stats, "poweroff": do_poweroff}


    def serve(conn):
        with conn:
            while True:
                try:
                    req = read_frame(conn)
                except (EOFError, OSError, ValueError):
                    return
                if req.get("op") == "spawn":
                    try:
                        do_spawn(conn, req)
                    except Exception as exc:
                        try:
                            send_frame(conn, {"ok": False, "error": str(exc)})
                        except OSError:
                            pass
                    return
                try:
                    handler = OPS.get(req.get("op"))
                    resp = handler(req) if handler else {"ok": False, "error": "Operacion desconocida"}
                except Exception as exc:  # el error vuelve al host, no tumba el servicio
                    resp = {"ok": False, "error": str(exc)}
                try:
                    send_frame(conn, resp)
                except OSError:
                    return


    def main():
        # La carpeta de trabajo se llamaba ~/work: lo que hubiera dentro se conserva con el nombre nuevo.
        if os.path.isdir(OLD_WORK) and not os.path.exists(WORK):
            os.rename(OLD_WORK, WORK)
        os.makedirs(WORK, exist_ok=True)
        server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        server.bind((socket.VMADDR_CID_ANY, PORT))
        server.listen(16)
        while True:
            conn, _ = server.accept()
            threading.Thread(target=serve, args=(conn,), daemon=True).start()


    if __name__ == "__main__":
        main()
    """#

    static let unit = """
    [Unit]
    Description=SaySo guest agent
    After=local-fs.target

    [Service]
    User=\(user)
    WorkingDirectory=/home/\(user)
    ExecStart=/usr/bin/python3 /usr/local/bin/sayso-guest
    Restart=always
    RestartSec=1

    [Install]
    WantedBy=multi-user.target
    """

    /// `user-data` de cloud-init (fuente NoCloud).
    public static var userData: String {
        func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        return """
        #cloud-config
        hostname: sayso
        users:
          - name: \(user)
            shell: /bin/bash
            lock_passwd: true
            sudo: "ALL=(ALL) NOPASSWD:ALL"
        write_files:
          - path: /usr/local/bin/sayso-guest
            permissions: "0755"
            encoding: b64
            content: \(b64(script))
          - path: /etc/systemd/system/sayso-guest.service
            permissions: "0644"
            encoding: b64
            content: \(b64(unit))
        runcmd:
          - "[ -d /home/\(user)/work ] && [ ! -e /home/\(user)/sayso ] && mv /home/\(user)/work /home/\(user)/sayso || true"
          - [mkdir, -p, /home/\(user)/sayso]
          - [chown, -R, "\(user):\(user)", /home/\(user)]
          - [systemctl, daemon-reload]
          - "systemctl disable --now ssh.service ssh.socket man-db.timer e2scrub_all.timer 2>/dev/null || true"
          - "systemctl set-default multi-user.target"
          - "systemctl stop lightdm.service 2>/dev/null || true"
          - [systemctl, enable, sayso-guest.service]
          - [systemctl, restart, sayso-guest.service]

        """
    }

    /// `network-config` de cloud-init: DHCP en cualquier interfaz Ethernet. Sin esto, la imagen ata
    /// la red a la dirección MAC del primer arranque y la pierde si cambia.
    public static let networkConfig = """
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: true
        dhcp6: true

    """

    /// `meta-data` de cloud-init. El identificador cambia con el contenido de `user-data` y de `network-config`, de modo
    /// que una versión nueva del agente invitado se reinstala sola en el siguiente arranque.
    public static var metaData: String {
        let digest = SHA256.hash(data: Data((userData + networkConfig).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "instance-id: sayso-\(digest)\nlocal-hostname: sayso\n"
    }
}

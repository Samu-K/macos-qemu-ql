#!/usr/bin/env python3
"""Minimal QMP client for scripts/test.sh.

    qmp.py SOCKET COMMAND [JSON-ARGUMENTS]

Prints the command's "return" value as JSON. Exits 1 if QEMU replies with an
error, 2 if the socket cannot be reached.
"""

import json
import socket
import sys


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, command = sys.argv[1], sys.argv[2]
    request = {"execute": command}
    if len(sys.argv) == 4:
        request["arguments"] = json.loads(sys.argv[3])

    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(30)
        sock.connect(path)
    except OSError as e:
        print(f"qmp: cannot connect to {path}: {e}", file=sys.stderr)
        return 2

    with sock, sock.makefile("rw") as f:
        f.readline()  # greeting

        def call(req):
            f.write(json.dumps(req) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:  # QEMU closed the socket, e.g. after "quit"
                    return {"return": {}}
                reply = json.loads(line)
                if "return" in reply or "error" in reply:
                    return reply

        call({"execute": "qmp_capabilities"})
        reply = call(request)

    if "error" in reply:
        print(f"qmp: {command}: {reply['error'].get('desc')}", file=sys.stderr)
        return 1
    print(json.dumps(reply["return"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys

from .adapter import GatewayClient, run_stdio
from .native import NativeBroker, NativeError
from .protocol import Protocol
from .security import DEFAULT_STATE, initialize, private_directory
from .server import GatewayServer
from . import changes, service


def main(argv=None):
    parser = argparse.ArgumentParser(description="Private native Calendar MCP transport")
    sub = parser.add_subparsers(dest="command", required=True)
    service.add_parser(sub)
    changes.add_parser(sub)
    for command in ("init", "serve", "stdio", "status"):
        item = sub.add_parser(command)
        item.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
        if command != "init":
            item.add_argument("--port", type=int, default=8765)
        if command == "serve":
            item.add_argument("--helper", type=Path, required=True)
            item.add_argument("--backend", choices=("eventkit", "synthetic"), default="synthetic")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        if args.command == "service":
            return service.dispatch(args)
        elif args.command == "changes":
            return changes.dispatch(args)
        elif args.command == "init":
            initialize(args.state_dir)
            print("Private local credential ready; contents were not displayed.")
        elif args.command == "stdio":
            return run_stdio(GatewayClient(args.state_dir, args.port))
        elif args.command == "status":
            reply = GatewayClient(args.state_dir, args.port).status()
            if not isinstance(reply, dict) or reply.get("gateway") != "reachable" or not isinstance(reply.get("native"), dict):
                raise ValueError("Unexpected gateway status response")
            print(json.dumps(reply))
            return 1 if "error" in reply["native"] else 0
        else:
            from .security import read_token
            if not 1 <= args.port <= 65535:
                raise ValueError("Invalid local port")
            state = private_directory(args.state_dir)
            token = read_token(state)
            # Separate native state, private credential cannot be confused with signing state.
            native_state = private_directory(state / ("native-" + args.backend))
            broker = NativeBroker(args.helper, native_state, args.backend,
                                  credential_binding=hashlib.sha256(token.encode("ascii")).hexdigest())
            try:
                with GatewayServer(args.port, token, Protocol(broker), state_directory=state) as server:
                    def stop(signum, frame):
                        raise KeyboardInterrupt()
                    signal.signal(signal.SIGTERM, stop)
                    print("Calendar MCP listening on protected local transport; backend=" + args.backend, file=sys.stderr)
                    server.serve_forever(poll_interval=0.25)
            finally:
                broker.close()
        return 0
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, NativeError):
        # Exceptions may contain a credential, command path, native data or remote text.
        print("Calendar MCP failed. Check private file permissions, port and native helper; no request is automatically retried.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

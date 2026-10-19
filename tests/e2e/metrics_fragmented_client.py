"""The metrics fragmented-GET probe, runnable in python:3-alpine."""
import socket
import sys
import time


def main(argv=None):
    host, port = sys.argv[1:] if argv is None else argv
    connection = socket.create_connection((host, int(port)), timeout=8)
    try:
        connection.sendall(b"GET /met")
        time.sleep(0.02)
        connection.sendall(b"rics HTTP/1.1\r\n\r\n")
        time.sleep(0.3)
        data = connection.recv(65536)
        assert data.startswith(b"HTTP/1.1 200"), "fragmented GET did not return HTTP 200"
        assert b"pg_logtap_" in data, "metrics body missing"
        print("frag-get ok:", data.split(b"\r\n", 1)[0].decode())
    finally:
        connection.close()


if __name__ == "__main__":
    main()

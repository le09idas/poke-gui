"""Connect to lua/yellow.lua's server and show (or save) one state message.

Usage:
    python tools/peek_state.py                        # short summary
    python tools/peek_state.py --raw                  # pretty-print the whole message
    python tools/peek_state.py --save overworld.json  # bare name -> fixtures/overworld.json

mGBA must be running with the script loaded and the game unpaused
(the script only sends data on frames).
"""
import argparse
import json
import socket
import sys
from pathlib import Path

FIXTURES_DIR = Path(__file__).resolve().parent.parent / "fixtures"


def read_one_message(host: str, port: int) -> str:
    """Connect, read a single newline-terminated JSON message, disconnect."""
    with socket.create_connection((host, port), timeout=5) as sock:
        with sock.makefile("r", encoding="utf-8") as stream:
            return stream.readline()


def summarize(msg: dict) -> None:
    state = msg["state"]
    print(f"protocol {msg['protocol']}, game {msg['game']}, frame {msg['frame']}")

    player = state.get("player")
    if player:
        print(f"player:   {player['name']} on {player['map']['name']} (X {player['x']}, Y {player['y']})")

    team = state.get("team")
    if team:
        names = ", ".join(f"{m['name']} Lv{m['level']}" for m in team["mons"])
        print(f"team:     {names}")

    bag = state.get("bag")
    if bag:
        print(f"bag:      {len(bag['items'])} item(s)")

    pc_items = state.get("pcItems")
    if pc_items:
        print(f"pc items: {len(pc_items['items'])} item(s)")

    pc_boxes = state.get("pcBoxes")
    if pc_boxes:
        counts = " ".join(str(box["count"]) for box in pc_boxes["boxes"])
        total = sum(box["count"] for box in pc_boxes["boxes"])
        print(f"pc boxes: {total} Pokemon (per box: {counts}; current box {pc_boxes['currentBox']})")

    dex = state.get("pokedex")
    if dex:
        print(f"pokedex:  seen {dex['seen']}, owned {dex['owned']}")

    battle = state.get("battle")
    if battle:
        line = f"battle:   {battle['battle']}"
        if battle["battle"] != "none":
            opponent = battle["opponent"]
            if opponent.get("trainer"):
                line += f" vs {opponent['trainer']}"
            for mon in opponent["mons"]:
                marker = ">" if mon.get("active") else " "
                line += f"\n          {marker} {mon['name']} Lv{mon['level']}  HP {mon['hp']}/{mon['maxHP']}"
        print(line)

    print(f"tabs:     {', '.join(sorted(state))}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--raw", action="store_true", help="print the whole message")
    parser.add_argument("--save", metavar="FILE",
                        help="write the message to FILE as pretty JSON (a bare name goes in fixtures/)")
    args = parser.parse_args()

    try:
        line = read_one_message(args.host, args.port)
    except OSError as e:
        sys.exit(f"Could not read from {args.host}:{args.port}: {e}\n"
                 "Is mGBA running with lua/yellow.lua loaded and the game unpaused?")
    if not line:
        sys.exit("Connected, but the server closed the connection before sending anything.")

    msg = json.loads(line)
    print(f"received {len(line.encode('utf-8')):,} bytes")

    if args.raw:
        print(json.dumps(msg, indent=2, ensure_ascii=False))
    else:
        summarize(msg)

    if args.save:
        path = Path(args.save)
        if path.parent == Path("."):        # bare file name -> the repo's fixtures/ folder
            path = FIXTURES_DIR / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(msg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"saved to {path}")


if __name__ == "__main__":
    main()

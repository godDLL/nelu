#!/usr/bin/env python3
"""Drive two clients against plan/tic-tac-toe.nelua and verify the game."""
import socket, sys, threading, time, os, subprocess

SOCK = sys.argv[1] if len(sys.argv) > 1 else "tmp/tt-test.sock"

LINES = [(0,1,2),(3,4,5),(6,7,8),(0,3,6),(1,4,7),(2,5,8),(0,4,8),(2,4,6)]
def idx(r, c): return (r - 1) * 3 + (c - 1)
def winner(b):
    for a, d, e in LINES:
        if b[a] and b[a] == b[d] == b[e]:
            return b[a]
    return None
def expected(moves):
    b = [None]*9
    for i, (r, c) in enumerate(moves):
        b[idx(r,c)] = 'X' if i % 2 == 0 else 'O'
    w = winner(b)
    return ("WIN " + w) if w else "DRAW"

def read_line(fh):
    line = b""
    while True:
        ch = fh.read(1)
        if not ch: return None
        if ch == b"\n": return line.decode()
        line += ch

def player(name, sock, script, results):
    """script: iterable of inputs to send on successive YOUR_TURN prompts.
    A str input is sent verbatim; a (r,c) tuple is sent as 'r c'. INVALID/
    TAKEN responses are tolerated and recorded."""
    fh = sock.makefile("rwb")
    si = 0
    while True:
        raw = read_line(fh)
        if raw is None:
            results.setdefault("eof_" + name, True); return
        line = raw
        if line.startswith("SYMBOL "):
            assert line.split()[1] == name, f"{name} got {line}"
        elif line == "YOUR_TURN":
            assert si < len(script), f"{name} ran out of scripted inputs"
            inp = script[si]; si += 1
            # string inputs are sent verbatim WITH a trailing newline (the
            # server's line reader blocks until it sees one); (r,c) tuples
            # are sent as "r c\n".
            fh.write((inp + "\n").encode() if isinstance(inp, str)
                     else f"{inp[0]} {inp[1]}\n".encode())
            fh.flush()
        elif line == "WAIT":
            pass
        elif line.startswith("BOARD"):
            for _ in range(4): read_line(fh)   # header + 3 rows
        elif line.startswith("WIN ") or line == "DRAW":
            results["result_" + name] = line; return
        elif line.startswith("INVALID"):
            results.setdefault("invalid", []).append(name)
        elif line.startswith("TAKEN"):
            results.setdefault("taken", []).append(name)
        elif line == "OPPONENT_LEFT":
            raise AssertionError(f"{name} opponent left")
        else:
            raise AssertionError(f"{name} unknown: {line!r}")

def connect_ordered():
    """Connect two clients in order; the server assigns X to the first."""
    sx = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); sx.connect(SOCK)
    so = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); so.connect(SOCK)
    return sx, so

def run_game(moves, label):
    if os.path.exists(SOCK): os.unlink(SOCK)
    srv = subprocess.Popen(["tmp/tic-tac-toe", SOCK],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(0.4)
    sx, so = connect_ordered()
    exp = expected(moves)
    results = {}
    t1 = threading.Thread(target=player, args=("X", sx, moves[0::2], results))
    t2 = threading.Thread(target=player, args=("O", so, moves[1::2], results))
    t1.start(); t2.start(); t1.join(timeout=10); t2.join(timeout=10)
    out, _ = srv.communicate(timeout=5); srv.wait()
    try: os.unlink(SOCK)
    except FileNotFoundError: pass
    assert results.get("result_X") == exp, f"X saw {results.get('result_X')}, want {exp}"
    assert results.get("result_O") == exp, f"O saw {results.get('result_O')}, want {exp}"
    assert "eof_X" not in results and "eof_O" not in results, "client EOF"
    print(f"[{label}] OK: both players saw {exp}")
    return out.decode()

def run_error_game(xscript, oscript, label, expect_invalid=False, expect_taken=False):
    if os.path.exists(SOCK): os.unlink(SOCK)
    srv = subprocess.Popen(["tmp/tic-tac-toe", SOCK],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(0.4)
    sx, so = connect_ordered()
    results = {}
    t1 = threading.Thread(target=player, args=("X", sx, xscript, results))
    t2 = threading.Thread(target=player, args=("O", so, oscript, results))
    t1.start(); t2.start(); t1.join(timeout=10); t2.join(timeout=10)
    out, _ = srv.communicate(timeout=5); srv.wait()
    try: os.unlink(SOCK)
    except FileNotFoundError: pass
    assert "eof_X" not in results and "eof_O" not in results, "client EOF"
    if expect_invalid: assert "invalid" in results and "X" in results["invalid"], "no INVALID seen"
    if expect_taken:   assert "taken" in results and "X" in results["taken"], "no TAKEN seen"
    print(f"[{label}] OK: result={results.get('result_X')} "
          f"invalid={len(results.get('invalid',[]))} taken={len(results.get('taken',[]))}")
    return out.decode()

# Game 1: a draw.
draw = [(1,1),(1,2),(1,3),(2,1),(2,2),(3,1),(2,3),(3,3),(3,2)]
run_game(draw, "draw")

# Game 2: X wins on the 0-4-8 diagonal.
xwin = [(2,2),(1,2),(3,3),(1,3),(1,1)]
run_game(xwin, "X-win")

# Game 3: X sends an invalid move, then recovers to a draw.
draw_x = draw[0::2]   # (1,1) (1,3) (2,2) (2,3) (3,2)
draw_o = draw[1::2]   # (1,2) (2,1) (3,1) (3,3)
run_error_game(["abc"] + list(draw_x), list(draw_o), "invalid-recovery",
               expect_invalid=True)

# Game 4: X sends a taken-cell move, then recovers to a draw.
run_error_game([(1,1), (1,1)] + list(draw_x[1:]), list(draw_o), "taken-recovery",
               expect_taken=True)

print("ALL TESTS PASSED")
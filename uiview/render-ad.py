#!/usr/bin/env python3
"""Capture the SaucePalette ad player (player.html) to an MP4 with audio.

Drives the player's deterministic seek(t) frame-by-frame (no wall-clock), pipes
JPEG frames to ffmpeg via the promo VideoComposer, then lays a cheesy audio bed
(typewriter keystrokes while typing, pops on the run/batch beats) and muxes it.

    render-ad.py [--out out/saucepalette-ad.mp4] [--fps 24] [--player out/player.html]
    render-ad.py --frame 2.4 --frame-out out/_f.png      # one frame, for iteration

Reuses promo/promo/{composer,audio}.py — no promo-pipeline changes.
"""
import argparse
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROMO = os.path.normpath(os.path.join(HERE, "..", "..", "promo"))
sys.path.insert(0, PROMO)
from promo.composer import VideoComposer          # noqa: E402
from promo import audio as A                       # noqa: E402
from playwright.sync_api import sync_playwright    # noqa: E402


def beat_times(storyboard_path):
    """Cumulative start time (s) per beat label, plus total duration."""
    data = json.load(open(storyboard_path, encoding="utf-8"))
    out, acc = [], 0.0
    for b in data["frames"]:
        dur = (b.get("durationMs", 800)) / 1000.0
        out.append({"label": b.get("label"), "kind": b.get("kind"),
                    "start": acc, "end": acc + dur})
        acc += dur
    return out, acc


def build_audio(beats, duration, wav_path):
    """Typewriter clicks across the typing beats; accent pops on key beats."""
    TYPING = {"b", "ba", "bar", "barr", "barri"}
    typing = [b for b in beats if b["label"] in TYPING]
    spans = []
    if typing:
        spans = [(typing[0]["start"], typing[-1]["end"])]
    accents = [b["start"] for b in beats if b["label"] in ("barri", "bleeding", "batch")]
    A.build_audio_track(
        message_timestamps=accents,
        total_duration=duration,
        output_path=wav_path,
        style="terminal",
        typing_spans=spans,
    )


def render(player_html, out_mp4, fps):
    url = "file:///" + os.path.abspath(player_html).replace("\\", "/")
    storyboard = os.path.join(os.path.dirname(player_html), "storyboard.json")
    beats, duration = beat_times(storyboard)
    total = max(1, int(round(duration * fps)))
    print("[render-ad] %.2fs @ %dfps = %d frames" % (duration, fps, total))

    with tempfile.TemporaryDirectory() as tmp:
        silent = os.path.join(tmp, "silent.mp4")
        wav = os.path.join(tmp, "bed.wav")
        comp = VideoComposer(silent, fps=fps, width=1920, height=1080)
        comp.start()
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 1920, "height": 1080})
            page.add_init_script("window.__capture = true;")
            page.goto(url, wait_until="networkidle")
            page.evaluate("window.__ready")
            stage = page.locator("#stage")
            for i in range(total):
                page.evaluate("window.PLAYER.seek(%f)" % (i / fps))
                comp.write_frame(stage.screenshot(type="jpeg", quality=90))
                if i % 24 == 0:
                    sys.stdout.write("\r  frame %d/%d" % (i, total)); sys.stdout.flush()
            browser.close()
        comp.finish()
        print("\r  frames done           ")
        build_audio(beats, duration, wav)
        A.mux_audio(silent, wav, os.path.abspath(out_mp4))
    size = os.path.getsize(out_mp4)
    print("[render-ad] wrote %s (%d KB)" % (out_mp4, size // 1024))


def one_frame(player_html, t, out_png):
    url = "file:///" + os.path.abspath(player_html).replace("\\", "/")
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        page.add_init_script("window.__capture = true;")
        page.goto(url, wait_until="networkidle")
        page.evaluate("window.__ready")
        page.evaluate("window.PLAYER.seek(%f)" % t)
        page.wait_for_timeout(60)
        page.locator("#stage").screenshot(path=out_png)
        browser.close()
    print("[render-ad] frame %ss -> %s" % (t, out_png))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--player", default=os.path.join(HERE, "out", "player.html"))
    ap.add_argument("--out", default=os.path.join(HERE, "out", "saucepalette-ad.mp4"))
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--frame", type=float, default=None)
    ap.add_argument("--frame-out", default=os.path.join(HERE, "out", "_frame.png"))
    args = ap.parse_args()
    if args.frame is not None:
        one_frame(args.player, args.frame, args.frame_out)
    else:
        render(args.player, args.out, args.fps)


if __name__ == "__main__":
    main()

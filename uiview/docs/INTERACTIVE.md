# UIView interactive mode — design (2026-07-02)

The ask: click, scroll, and type against the REAL mod UI in the browser
viewer, not just inspect static frames. Nothing fundamental blocks it — the
harness already runs the real widget tree on PZ's actual Kahlua VM, the
elements carry their real input callbacks (onMouseDown / onMouseWheel /
onOtherKey), UIView_setMouse exists for hover state, and re-rendering a
frame is one Render.frame call. What's missing is a LOOP that carries
browser input back into the VM.

## Architecture (three small pieces)

1. **VM loop** — a driver the existing java runner executes instead of the
   test suite (`pztest --interactive <scene>`): build the scene once, then
   read JSON lines from stdin forever. Each line is an event
   (`{"t":"click","x":120,"y":88}`, `{"t":"wheel","dy":-1}`,
   `{"t":"key","key":"a"}`); dispatch it into the tree the way PZ's
   UIManager would (hit-test children topmost-first for mouse, focused
   element for keys, UIView_setMouse for hover), then Render.frame and
   print the ops JSON between sentinels. If Kahlua's io.read is not exposed,
   the loop lives in KahluaTestRunner.java (a dozen lines: readLine ->
   env call -> flush).

2. **Bridge** — `interact.py`: spawns the VM loop as a child process and
   serves localhost HTTP. POST /event writes a line to the child's stdin,
   reads ops until the sentinel, returns the display list. GET / serves the
   viewer. ~80 lines, stdlib only.

3. **Viewer input capture** — viewer.template.html already draws the ops;
   add listeners that translate canvas mouse/wheel/key events into scene
   coordinates, POST them, and repaint from the response. Latency budget is
   trivial (one JVM round trip per event; frames are a few KB of JSON).

## What it buys

- Reproduce interaction bugs headlessly: the collapse tween, chip clicks,
  sort-header clicks, scroll behavior (the entire band-rides-the-scroll
  saga would have been a 10-second browser check).
- Scriptable interaction TESTS: the same event-line protocol works without
  the browser -- feed a canned event script, assert on the resulting ops
  (click chip "Food" -> only Food rows painted).
- Demo capture: drive an interaction script, save every frame, feed the
  existing player/gif pipeline -- promo clips of REAL interactions.

## Honest limits

- Java-backed widgets (UITextBox2 text entry) are mocked: typing goes
  through our mock's text buffer, not PZ's java caret behavior.
- Timing-dependent behavior (blink, tween) renders by T.now(); the loop
  should pass a monotonic fake clock in events so tweens animate
  deterministically.
- It replicates the UI LAYER faithfully, not gameplay: handlers that reach
  into live game state (transfer actions) hit the scene's mocks.

## Sequence

1. Event-dispatch module (UIView/Interact.lua): hit-testing + focus rules,
   usable by tests immediately (no server needed) -- highest value first.
2. Scripted-interaction tests for SIR search band + sort headers.
3. The stdin loop + interact.py + viewer capture (the live browser mode).

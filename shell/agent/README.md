# pz-shell agent

A single Java class that gives pz-shell back the ability to turn a string into a
callable Lua function. Required on Project Zomboid builds from **2026-08**
onward (buildid 24909800+). Not needed on older builds.

## Why

PZ's 2026-08 security patch removed `loadstring` and `loadstream` from the Lua
environment. A REPL cannot work without one of them: there is no other way in
pure Lua to compile source at runtime.

**It removed the binding, not the compiler.** Verified against the patched jar:

- `se.krka.kahlua.luaj.compiler.LuaCompiler` is byte-identical to the pre-patch
  build — its static initialiser still builds `names = {"loadstring","loadstream"}`.
- `LuaCompiler.loadstring(String, String, KahluaTable)` and the `loadis`
  overloads are still `public static`, and PZ itself calls `loadis` every time it
  loads a `.lua` file off disk (`LuaManager.java:1367`).
- What changed is that `LuaManager` no longer calls `LuaCompiler.register(...)`,
  which is what installed the globals. Its siblings — `LuaEventManager.register`,
  `LuaHookManager.register`, `CoopMaster.register` — still fire.

So the machinery is intact and reachable from Java; only the Lua-side binding was
withdrawn. This agent re-exposes it and nothing else. It is not a
reimplementation: same compiler, same environment table, same `LuaClosure`.

## What it exposes

| Global | Returns |
|---|---|
| `PZShell_loadchunk(code, chunkname)` | `LuaClosure`, or `nil` on a compile error |
| `PZShell_lastError()` | the last compile error message, or `nil` |
| `PZShell_agentVersion()` | agent version — liveness probe |
| `PZShell_envIsShared()` | `true` if the compile environment is the mod VM's |

`PZShell.compile()` in `PZShell.lua` is the only caller. It falls back to
`loadstring` on pre-patch builds and, failing both, returns a message saying
exactly what is missing rather than dying with "attempt to call nil".

`PZShell_envIsShared` is worth running once on a new build. The agent compiles
against `LuaManager.env` — the table `platform.newEnvironment()` produced at boot
(`LuaManager.java:1092`), i.e. the mod VM's own globals. If PZ ever ran the
server VM in a separate environment, probes would silently see an empty world;
this asserts they don't.

## Wiring

ZombieBuddy does **not** scan for jars. It reads two lines from the mod's
`mod.info`, both relative to the version folder:

```
javaJarFile=media/java/shared/PZShellAgent.jar
javaPkgName=com.darksauce.pzshell
```

Miss either and the jar deploys, is never loaded, `PZShell_loadchunk` stays nil,
and `eval` fails with no indication why.

Deliberately **not** declared: `require=\ZombieBuddy`. VPSFx does that because it
is completely inert without the agent; pz-shell is not — `tail`, `reload` and
`profile` all still work. A hard require would make the whole mod fail to load
for anyone without ZombieBuddy, to protect one of its four features.

And the agent only attaches at all if the JVM was started with
`-javaagent:ZombieBuddy.jar` — Steam launch options, or `vmArgs` in
`ProjectZomboid64.json`. That is a per-machine setting no mod can assert.

## Build

Requires ZombieBuddy installed (`ZombieBuddy.jar` in the PZ install root) and a
JDK with `jar.exe`.

```powershell
.\build.ps1                       # -> ../mod/media/java/shared/PZShellAgent.jar
.\build.ps1 -PZDir "D:\PZ"        # non-default install
```

Compiling is itself a check: if `LuaCompiler.loadstring` or `LuaManager.env`
ever move, the build fails rather than the shell failing at runtime.

Then deploy the mod as usual (`../deploy.sh`) and launch with ZombieBuddy active.
ZombieBuddy picks agent jars up from a mod's `media/java/shared/`.

## Scope

Dev tooling. This is arbitrary code execution by design — that is what a REPL
is — which is why the mod stays behind its `enabled` gate file and ships in
pz-test-kit rather than in any released mod. Don't put it on a public server.

# Fix: Uncontrolled / Disconnected Mouse Feel in Valorant — Wrong `MaxResolution` in Monitor Registry Entry

## TL;DR
Valorant reads its target monitor from `GameUserSettings.ini` via a Windows monitor class registry key. On my laptop (BOE090F internal panel), that registry entry was reporting a stale `MaxResolution` of `1600,1200` instead of the panel's actual native `1920,1080`. Correcting the value in two places under `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}\0002` and rebooting fixed an "uncontrolled" / hard-to-track mouse feel I was getting in Valorant — not a "floaty" (smoothed/laggy) feeling specifically, more like the aim just didn't feel precise or locked-in.

To be clear about what I think this actually is: I don't believe this setting was *adding* some kind of floatiness that got removed. My best guess is Valorant/the OS was working off of a mismatched resolution capability value, and correcting it just made the game operate in the state it should have been in all along — rather than "fixing" a specific unwanted effect on top of a normal baseline.

I can't fully explain the exact mechanism (this registry key is generally considered legacy EDID metadata not used by the modern DXGI/D3D rendering path), but the before/after difference was consistent and repeatable on my end, so I'm documenting it here in case it helps someone else — and in case someone with deeper knowledge of the Windows display stack wants to explain *why* this had an effect.

---

## 1. Checking the path

I started by checking `GameUserSettings.ini` to see which monitor Valorant was actually targeting.

<img width="1130" height="200" alt="image" src="https://github.com/user-attachments/assets/f722687d-cb93-4580-8726-89b9df54ae12" />


```ini
[/Script/ShooterGame.ShooterGameUserSettings]
DefaultMonitorDeviceID="MONITOR\BOE090F\{4d36e96e-e325-11ce-bfc1-08002be10318}\0002"
DefaultMonitorIndex=0
LastConfirmedDefaultMonitorDeviceID="MONITOR\BOE090F\{4d36e96e-e325-11ce-bfc1-08002be10318}\0002"
LastConfirmedDefaultMonitorIndex=0
```

- `BOE090F` — the actual hardware ID of my internal panel (BOE is the panel manufacturer)
- `{4d36e96e-e325-11ce-bfc1-08002be10318}` — the Windows **Monitor device class GUID**
- `0002` — the specific instance number under that class

This pointed me straight to a specific key in the registry.

## 2. Something interesting

Opening that exact path in Regedit:

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}\0002
```

<img width="1115" height="377" alt="image" src="https://github.com/user-attachments/assets/623f76f9-9fc3-4e97-b25a-000764522ebe" />


Even though my laptop's real native resolution is **1920x1080**, this entry listed:

```
MaxResolution: 1600,1200
DriverDesc:    Generic PnP Monitor
MatchingDeviceId: *PNP09FF
```

Same stale value shows up one level down, under `Configuration\Driver`:

<img width="1080" height="379" alt="image" src="https://github.com/user-attachments/assets/fb3a6e69-ef2c-47cf-8722-f41ae0aabfe1" />


```
$!MaxResolution: 1600,1200
```

`*PNP09FF` is Windows' generic fallback monitor ID (used when the OS doesn't have a model-specific INF for the panel), and `1600,1200` looks like an old default baked into the generic `monitor.inf` driver rather than anything read from my actual panel.

## 3. The fix

I edited both `MaxResolution` values (under the `0002` key directly, and under `0002\Configuration\Driver`) to match my panel's real native resolution:

<img width="1102" height="558" alt="image" src="https://github.com/user-attachments/assets/ddac39a7-3200-40fd-ad4f-564d2f0d619f" />


<img width="1070" height="558" alt="image" src="https://github.com/user-attachments/assets/82fafe27-8d08-4ec5-966e-1170c601a8c6" />


```
MaxResolution:   1920,1080
$!MaxResolution: 1920,1080
```

(If your native resolution is different, e.g. 2560x1440 or 3840x2160, use *your* actual resolution here, not mine.)

## 4. Result

After a full restart, the uncontrolled/hard-to-track mouse feeling in Valorant was gone. I wouldn't describe it as "floaty" got fixed — it's more that the mouse now feels the way it's supposed to feel by default, like the game was just running off bad monitor data before and this corrected that baseline rather than removing some separate floaty effect layered on top.

---

## Caveats / honesty section

I want to be upfront about a few things before anyone else tries this:

1. **I don't have a confirmed technical explanation for why this worked.** This registry key is generally treated as legacy monitor metadata (used by some old `GetDeviceCaps`-style APIs), not something the modern DXGI/D3D render or raw-input pipeline is supposed to touch. It's possible something downstream (an internal capability check, a UE4/5 monitor enumeration edge case, or something else entirely) does read it — but I haven't proven the causal mechanism, only observed the before/after difference.
2. **This could be coincidental.** A reboot alone changes a lot of state (driver re-init, background processes, etc.). I didn't isolate the registry edit from the reboot as separate variables.
3. **Editing the registry is at your own risk.** Back up the key before editing (right-click the `0002` key → Export) in case anything looks different after.
4. **Your GUID/instance number will very likely be different.** Don't blindly copy `{4d36e96e-e325-11ce-bfc1-08002be10318}\0002` — find *your* panel's entry the way I did, by reading `DefaultMonitorDeviceID` out of your own `GameUserSettings.ini` first.

If anyone with deeper knowledge of the Windows display/EDID stack knows why this actually made a measurable difference, I'd genuinely like to know — happy to test further and report back.

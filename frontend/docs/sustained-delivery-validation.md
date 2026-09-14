# Sustained delivery: field validation, and the gate that depends on it

**Gate state: CLOSED.** No cell of the matrix below has been run. Nothing about
this capability has been observed on any phone, on any date, by anybody. The
capability is therefore not offered in the artifact that reaches a user, and
`lib/app/config/sustained_delivery_gate.dart` is what makes that true rather
than intended.

**Updated 2026-08-23:** one physical device — a Samsung Galaxy A56 on Android 16
and One UI 8.5 — became available and was **probed**, not run. It establishes
that the procedure works on retail Samsung hardware, corrects a timing this
document had only from an emulator, and found two defects in the instrument
itself. It opens no cell and moves the gate not at all: a probe is not a run.

Decided by [ADR-053](decisions.md), which amends ADR-051's distribution clause.
This document is authoritative for the success criteria, the matrix, the
measurement procedure and the recorded results. The gate constant is
authoritative for what the software does about them.

---

## 1. What is being validated

ADR-051's opt-in *sustained delivery*: a `specialUse` foreground service that
keeps this application's process out of Android's cached state so that the
delivery session's WebSocket to the provisioned backend survives while the
application is not in use, with the battery-optimization exemption to keep that
connection alive through Doze.

It rests on three things, and they are three different kinds of thing:

- **Guaranteed by the platform** — that a cached process is frozen and a frozen
  app's TCP sockets are terminated; that an app in the *rare* or *restricted*
  standby bucket has background network *disabled*; that a force-stopped app
  runs nothing. These are guaranteed *restrictions*. Measurement cannot disprove
  them and is not attempted.
- **Permitted, never promised** — that a foreground service keeps running; that
  an exempt app keeps network through Doze; that `specialUse` continues to carry
  no timeout. Android's own wording is permission, not guarantee.
- **Not governed by the platform at all** — whether the manufacturer of the
  phone leaves the process alone. Roughly nine in ten Android devices in this
  deployment's country come from two manufacturers who both document suspending
  background applications on their own schedule.

Only the third and second can be measured, and only on hardware. That is what
this document exists for.

---

## 2. How the fleet was derived

**Source:** Statcounter Global Stats, Islamic Republic of Iran.
**Period:** twelve months, 2025-08 to 2026-07 inclusive; 2026-07 is the most
recent complete month.
**Read:** 2026-08-23.

- Mobile vendor share:
  <https://gs.statcounter.com/vendor-market-share/mobile/iran>
- Android version share, mobile and tablet:
  <https://gs.statcounter.com/android-version-market-share/mobile-tablet/iran>

These figures were re-read for this piece rather than carried forward. ADR-046
and ADR-051 both quote Samsung 46.34% / Xiaomi 30.98%; the July 2026 figures are
46.31% and 30.99%, so those numbers survive — but the *use* both decisions made
of them does not, for the reason in §2.2.

### 2.1 Vendor share, July 2026

| Vendor | Share of all mobile | Share of the **Android** fleet |
|---|---:|---:|
| Samsung | 46.31% | **54.0%** |
| Xiaomi | 30.99% | **36.1%** |
| Apple | 14.25% | — (not an Android target) |
| Huawei | 3.20% | 3.7% |
| Unknown | 3.02% | 3.5% |
| Honor | 0.64% | 0.7% |
| everything else | ~1.6% | ~1.9% |

Twelve-month trend: Samsung between 44.8% and 50.1%, Xiaomi between 29.0% and
32.4%, in every month except 2026-03 and 2026-04, where Apple's share jumps to
26.6% and 30.7% and both Android vendors fall by roughly a fifth. Those two
months are treated as a sampling artefact of the panel and are excluded from the
trend statement; they are not excluded from the record, because a reader is
entitled to see that this source has months that do not behave.

### 2.2 Correction to what this repository already records

ADR-051 states that Samsung and Xiaomi are "roughly 77% of this fleet". That is
their share of *all* mobile devices, iPhones included. This deployment is an
Android-only artifact, so the fleet it will actually encounter excludes Apple,
and the correct figure is **about 90%** — Samsung 54.0% and Xiaomi 36.1% of the
Android devices. The repository understates its own vendor concentration by
thirteen points, in the one place where that concentration is the whole argument.

### 2.3 Platform-version share, July 2026

| Android | API | Share | Why this version band matters here |
|---|---:|---:|---|
| 16 | 36 | 14.13% | jobs concurrent with a foreground service adhere to the job runtime quota |
| 15 | 35 | 10.09% | `dataSync` timeout, `BOOT_COMPLETED` FGS restrictions |
| 14 | 34 | 15.76% | foreground service **types** mandatory; cached processes frozen 10 s after entering the cached state |
| 13 | 33 | 20.40% | `POST_NOTIFICATIONS`; Task Manager; **restricted bucket after 8 days** |
| 12 | 31 | 13.58% | restricted bucket exists, but at 45 days; FGS background-start restrictions |
| 11 | 30 | 13.54% | before all of the above |
| 10 and below | ≤29 | 12.49% | below the *restricted* bucket entirely; `minSdk` 24 excludes 5.x and 4.4 (0.39%) |

Twelve-month trend: Android 16 went from 0.02% to 14.13% in a year and is still
climbing; Android 15 fell from 16.99% to 10.09% as devices moved to 16; 11, 12
and 13 are flat within a point. **The version axis is moving fast enough that a
result is perishable**, which is why §8 fixes an expiry.

**Second correction.** ADR-051 states that "roughly half this fleet by version
share is Android 13 or earlier", and uses that to bound how much of the fleet
Samsung's One UI 6.0 statement covers. The figure is **60.0%**, not half.
Android 14 and later — the only band One UI 6.0+ can occupy — is 39.98%. So at
most two fifths of this fleet is covered by any vendor statement at all, and
that is before subtracting every Xiaomi device, for which no such statement
exists. The uncovered fraction is therefore **at least 60%, and in practice
about 78%** once Xiaomi is removed from the covered side.

### 2.4 The honest limit of all of this

This deployment has **20–30 known users receiving a private handover**. A
country-level panel statistic is a prior over an unobserved fleet; it is not the
fleet. The strongest possible derivation here is not Statcounter at all — it is
asking the twenty-odd people what phone they have. Nobody has. Until somebody
does, the matrix below is built on a proxy, and a proxy is what it should be
recorded as.

**Follow-up F1:** enumerate the actual devices at handover — manufacturer, model,
Android version, vendor skin version — and replace §2.3 with the real
distribution. That single act would shrink this matrix, or expand it, on fact.

---

## 3. Success criteria

**Fixed on 2026-08-23, before any measurement of any kind was attempted.**
Nothing here was written or adjusted after seeing a result. The device probes
recorded later that day (§6.1) came after this section was written and measure
no criterion in it: they establish what a device *is* and what it will
*permit*, and every threshold below is still waiting on a run. Each criterion states the condition, what is
observed, the threshold, the number of repetitions, and what separates a failure
from noise.

A criterion that turns out to be wrong is corrected in the open: the affected
measurements are discarded and re-run, or recorded as unusable. They are never
kept under a relaxed threshold.

### C1 — The service stays up

- **Condition.** Capability enabled and confirmed *holding*. Device unplugged,
  screen off, stationary, not attached to a workstation by cable, left alone.
- **Observed.** `dumpsys activity services <pkg>` every 60 s: the record for
  `SustainedDeliveryService` present, with `isForeground=true`.
- **Threshold.** Present and foreground at **100%** of samples for **≥ 24
  continuous hours**.
- **Repetitions.** 3 independent runs per cell, each from a fresh enable.
- **Failure vs noise.** Two consecutive samples without the service fails that
  run. A cell passes only at **3/3**. One or two passing runs out of three is
  **fail**, recorded as *intermittent* — an intermittent background capability
  is one that fails silently, which is the failure this whole piece exists to
  prevent.

### C2 — The connection stays up

- **Condition.** As C1.
- **Observed.** `/proc/net/tcp6` and `/proc/net/tcp`, filtered to the
  application's UID and the provisioned origin's port in state `01`
  (ESTABLISHED), every 60 s.
- **Threshold.** A socket present at **≥ 99%** of samples over the 24 hours, and
  **no gap longer than 10 minutes**. Ten minutes is the keepalive interval (4
  min) plus one unanswered ping (4 min) plus the supervisor's first backoff; a
  longer gap means something other than the designed reconnect happened.
- **Repetitions.** 3, with C1.
- **Failure vs noise.** A single sample gap is noise. A gap over 10 minutes, or
  a run below 99%, fails that run.

### C3 — Delivery is actually fast

- **Condition.** Receiver in deep Doze for **≥ 60 minutes**. A second, separate
  test account sends a message; the send is driven from the measuring host.
- **Observed.** Host wall-clock from the send mark to the first sample in which
  `dumpsys notification` shows this package's alert. Sampling at 5 s.
- **Threshold.** **p50 ≤ 30 s and p95 ≤ 120 s**, over **≥ 20 sends** spread
  across ≥ 12 hours with ≥ 15 minutes between sends.
- **Rationale for the numbers, stated before the measurement.** The mandatory
  floor beneath this is a periodic job at the platform minimum of 15 minutes,
  deferred further by Doze. A capability that costs a permanent notification, a
  battery exemption and a per-vendor setup step, and does not clear 120 s at p95,
  has not bought the user anything they would recognise.
- **Failure vs noise.** A send not delivered within 15 minutes is a **miss**.
  More than one miss in 20 fails the cell, regardless of the percentiles.

### C4 — It survives the standby path

- **Condition.** Device left genuinely unused for **≥ 9 days** — past the
  Android 13+ eight-day threshold into the *restricted* bucket — with no
  interaction with this application at all.
- **Observed.** `am get-standby-bucket` daily, plus C1, C2 and one C3 probe per
  day.
- **Threshold.** C1, C2 and C3 all still hold on day 9.
- **Repetitions.** 1 per cell. Expensive, and a failure is still a failure.
- **Note.** `am set-standby-bucket` is run as a **separate, labelled arm**, never
  as a substitute: forcing a bucket does not reproduce the system's own reason
  for assigning it, and Android does not document the command at all.

### C5 — It comes back after a restart

- **Condition.** Reboot with the capability on; unlock once; then leave alone.
- **Observed.** Time from first unlock until the service is running again.
- **Threshold.** Running within **20 minutes** of the first unlock (the 15-minute
  job floor plus slack), **3/3** reboots.

### C6 — It comes back after an update

- **Condition.** Install an updated artifact of the same identity over the top.
- **Threshold.** As C5, **3/3**.

### C7 — The manufacturer, unconfigured

- **Condition.** Factory-default battery settings. The user has **not** performed
  the manufacturer step, because the users of this deployment do not maintain
  settings and do not repeat setup.
- **Threshold.** C1 and C2 hold for ≥ 24 h.
- **C7′.** The same cell with the manufacturer exclusion performed, recorded
  **separately**. A cell that holds only under C7′ is recorded as passing C7′ and
  **failing C7**. It is never recorded as a pass.
- **What counts as a pass when the platform behaves and the manufacturer does
  not.** The cell **fails**. The gate is about the phone in a user's hand, not
  about AOSP.

### C8 — The manufacturer setting survives a system update

- **Condition.** A device with the vendor exclusion set and the Doze exemption
  granted, which then receives a manufacturer OTA.
- **Observed.** After the update: `dumpsys deviceidle whitelist` for the
  exemption, and the vendor list read by hand on the device.
- **Threshold.** Both still set.
- **Note.** This cannot be scheduled. It is opportunistic, and is recorded as
  *not yet observed* until an OTA happens to arrive during a run. That is a
  known weakness of this criterion and is stated rather than engineered around.

### C9 — The permanent entry is what ADR-051 says it is

- **Observed.** `dumpsys notification --noredact` shows the record with
  `vis=SECRET` and low importance; a photograph of the secure lock screen shows
  nothing; the Android 13+ Task Manager entry is present.
- **Threshold.** Exact match. One observation per cell — this is a property, not
  a rate.

### C10 — Off is a complete state

- **Condition.** (a) never enabled; (b) enabled then disabled.
- **Observed.** No service record, no notification record, no socket while
  backgrounded, no durable row.
- **Threshold.** All absent, in both cases.

### What a single failure means, and what it does not

A failure closes the cell it was observed in and **says nothing about any other
cell**: a Samsung result is not a Xiaomi result, an Android 13 result is not an
Android 16 result, and one day is not the next. It does, however, keep the
**gate** closed, because the gate requires every mandatory cell.

---

## 4. The matrix

Seven cells. Six are the fleet; the seventh is the control.

| Cell (ledger name) | Device | Fleet weight | Status |
|---|---|---:|---|
| `samsungAndroid11To12` | Samsung, Android 11 or 12, One UI 3–4 | ~14.6% | **NOT RUN** |
| `samsungAndroid13` | Samsung, Android 13, One UI 5.x | ~11.0% | **NOT RUN** |
| `samsungAndroid14Plus` | Samsung, Android 14/15/16, One UI 6.0+ | ~21.6% | **NOT RUN** — device available and probed (§6.1), nothing measured |
| `xiaomiAndroid11To12` | Xiaomi, Android 11 or 12, MIUI 13/14 | ~9.8% | **NOT RUN** |
| `xiaomiAndroid13` | Xiaomi, Android 13, MIUI 14 | ~7.4% | **NOT RUN** |
| `xiaomiAndroid14Plus` | Xiaomi, Android 14+, HyperOS | ~14.4% | **NOT RUN** |
| `platformReference` | Pixel or AOSP at the same API level as the Samsung/Xiaomi 13 cells | control | **NOT RUN** (substituted, §6.2) |

Fleet weight is vendor share of the Android fleet (§2.1) times version-band
share (§2.3), and is indicative only — it assumes vendor and version are
independent, which they are not.

**Why this set is representative.** The six fleet cells cover about
**79%** of the Android devices this deployment expects to meet: two
manufacturers at 90% combined, crossed with three version bands at 87.5%
combined. Nothing smaller covers the two variables the evidence says the answer
depends on — the manufacturer decides whether the process is allowed to live,
and the version decides which of the freezer, the eight-day restricted bucket
and the typed-foreground-service rules apply at all.

**Why the control cell is mandatory, and it is not for coverage.** Without a
device whose background behaviour is the platform's own, a failure cannot be
attributed. A capability that fails on Samsung *and* on a Pixel is broken; one
that fails on Samsung alone is a manufacturer deviation. Those are different
findings with different remedies, and no single run distinguishes them.

**What this matrix does not cover, stated plainly.**

- Huawei (~3.7% of the Android fleet) — no Google services, its own PowerGenie
  background management, and no device available.
- Honor (~0.7%), "Unknown" (~3.5%), and the long tail (~1.9%).
- Android 10 and below (12.49% of version share). The cached-apps freezer's
  documented behaviour is stated for Android 14 and higher; what an Android 10
  device does with a backgrounded socket is **not established here at all**, and
  it may be that this capability is unnecessary there or that it behaves
  differently. Either way, `minSdk` is 24 and those devices can install the
  artifact.
- Any device on a carrier whose NAT behaves differently from the ones tested.
  The four-minute keepalive is a value chosen from documentation, never measured
  against an Iranian carrier.

---

## 5. How the measurement is designed

### 5.1 How the behaviour is observed at all

**Nothing is added to the application.** No log line, no counter, no diagnostic
screen, no export, and above all no outbound call. This project forbids the
application reporting anything about itself to anybody, and an instrument that
required such a report would be an instrument that could survive into a
distributed build.

Everything is read from the **platform's own** debug surfaces over adb, by
`tool/measure_sustained_delivery.sh`:

| Question | Platform surface |
|---|---|
| Is the service up and foreground? | `dumpsys activity services <pkg>` |
| Is the connection open? | `/proc/net/tcp6`, filtered by app UID, origin port, state `01` |
| What state is the process in? | `dumpsys activity oom`, adj label and state triple |
| Is the device in Doze? | `dumpsys deviceidle get deep` / `get light` |
| Which standby bucket? | `am get-standby-bucket <pkg>` |
| Is the exemption held? | `dumpsys deviceidle whitelist` |
| Is the permanent entry displayed, and how? | `dumpsys notification --noredact` |

The consequence worth stating: **the device under test runs exactly the artifact
a user would run.** The measurement cannot alter what it measures, and there is
nothing to remove afterwards.

### 5.2 How time is measured on both ends

The **measuring host is the single time base**. It drives the sender over adb
and it reads the receiver over adb, so a send mark and the sample that first
shows the alert are two readings of one clock, and no clock has to be related to
any other. Device clock offset is recorded before and after each run
(`adb shell date -u +%s%3N` against the host) so that drift is visible rather
than assumed. No time service — domestic or foreign — is contacted by anything
in this procedure.

### 5.3 Reaching the conditions that take hours

Forced and natural are **two arms of the same cell, and whether they agree is
itself a result.**

- **Forced.** `dumpsys deviceidle force-idle` reaches deep idle in seconds. It
  skips light Doze, the inactivity timer and the motion gate entirely; the state
  machine names in `dumpsys deviceidle` show that directly.
- **Natural.** The device is physically off the charger, screen off, stationary,
  left alone; the harness only watches, and records how long entry actually took.

**A cell whose two arms disagree has no usable forced result**, and its forced
measurements are discarded. This is written down here, before any measurement,
precisely so that a convenient forced result cannot later be presented as if it
had been reached naturally.

The Doze constants are **read from each device** rather than assumed
(`dumpsys deviceidle`, captured by `probe`). They are not the same everywhere —
see §6.1 for an emulator that is nothing like a stock phone — and a procedure
that assumed one device's timings would mis-time every other.

### 5.4 What a realistic idle device looks like

A phone plugged into a workstation is charging, is being kept awake by the adb
connection, and never enters the natural Doze path. So:

- the device is **unplugged**, and adb reaches it over **Wi-Fi on the local
  network** (`adb tcpip 5555`, `adb connect`);
- the screen is off, the phone is stationary and face-down on a surface, not in
  a hand and not in a pocket;
- `dumpsys battery unplug` is used only in the forced arm, and never during a
  24-hour or 9-day run, because it is a simulation of the condition rather than
  the condition.

### 5.5 Numbers

Seven cells × 3 runs × 24 h for C1/C2, plus 20 timed deliveries per cell for C3,
plus one 9-day run per cell for C4, plus 3 reboots and 3 updates. Serialised on
one device per cell that is **at least 9 + 3 days of elapsed time per cell**, and
the cells are independent, so seven devices run in parallel finish in about a
fortnight. One device run serially would take roughly three months.

### 5.6 The manufacturer step, both ways

Every cell is run twice at C1/C2: once with the manufacturer's exclusion **not**
performed (C7) and once with it performed (C7′). The unconfigured arm is the one
that matters for this deployment, because its users do not maintain settings.
The configured arm exists to tell "this phone kills it" apart from "this phone
kills it *unless* the user does something".

### 5.7 The system-update question

There is no way to schedule a manufacturer OTA. The approach is:

1. devices are left on their default update channel and never held back;
2. `probe` is re-run after every OTA, so the platform version and vendor skin in
   the run record are always the ones the samples were taken under;
3. the exemption is re-read from `dumpsys deviceidle whitelist` at every sample,
   so a silent withdrawal appears in the data as the moment it happened;
4. the vendor list is a photograph, because no API reads it.

If no OTA arrives during the campaign, C8 is recorded **not observed**. It is
not inferred from anything.

### 5.8 What the data is, where it lives, what is in it

One directory per run under `docs/validation/sustained-delivery/`, containing
`probe.json`, `deviceidle.txt`, `samples.ndjson`, `marks.ndjson`. Contents:
timestamps, booleans, counts, and the device's own build identity.

**Never recorded:** message content, conversation, account, username, token,
key, notification text, server host, or IP address. The origin under test is
passed to the harness as a port and reduced to a socket **count** before
anything is written, so a run record can be committed here without disclosing
where this deployment lives or who is on it. Runs use dedicated test accounts,
never a real user's device or account.

### 5.9 Reproducibility

Every step above is a subcommand of `tool/measure_sustained_delivery.sh`, and
every threshold in §3 is either in that script's `verdict` output or in the
admissibility rules compiled into `lib/app/config/sustained_delivery_gate.dart`.
Somebody who has never read this document can run `probe`, `doze`, `watch`,
`mark`, `verdict` in that order and get a result they can compare against
criteria they can see.

---

## 6. Results

### 6.1 What was actually run

**Three probes — one on a real phone, two on emulators — and no run of any
kind.** That is the whole of it. A probe records what a device *is* and what it
will *permit*; it measures nothing about the capability, which has never been
started anywhere.

| Run | Hardware | Platform | Date | What it establishes |
|---|---|---|---|---|
| `2026-08-23-emulator-api35` | `Google sdk_gphone16k_x86_64` (`user` build, x86_64) | Android 15, API 35 | 2026-08-23 | that the observation surfaces in §5.1 all work unrooted; this image's Doze constants and freezer setting |
| `2026-08-23-emulator-api30` | `Google sdk_gphone_x86` (`user` build, x86) | Android 11, API 30 | 2026-08-23 | the same, and that both differ sharply from the API 35 image |
| `2026-08-23-samsung-a56` | **Samsung SM-A566B (Galaxy A56 5G)**, retail `user` build, `release-keys` | **Android 16, API 36, One UI 8.5** (`ro.build.version.oneui=80500`), patch 2026-07-05 | 2026-08-23 | that the whole procedure runs on retail Samsung hardware; this phone's real Doze constants; that the vendor intent the app ships resolves |

**Observed** (emulator, API 35, `AP31.240617.003`, 2026-08-23, one reading each):

- The cached-apps freezer is enabled: `dumpsys activity settings` reports
  `use_freezer=true` with `freeze_debounce_timeout=10000` — ten seconds, matching
  the documented "frozen 10 seconds after entering the cached state".
- Deep Doze can be entered from an unrooted `user` build:
  `dumpsys deviceidle force-idle` returns *"Now forced in to deep idle mode"* and
  `get deep` then reports `IDLE`.
- Standby buckets can be read and set without root: `am set-standby-bucket …
  rare` then `am get-standby-bucket` returns `40`.
- `/proc/net/tcp6` is readable from the `shell` user, so socket state is
  observable without instrumenting the application.
- `dumpsys notification --noredact` and `dumpsys deviceidle whitelist` are both
  readable, so the permanent entry's properties and the exemption are externally
  verifiable.

**Observed** (both emulators, 2026-08-23, one reading each), and this is the one
result of this run that changed a design decision:

| Doze constant | API 30 image | API 35 image |
|---|---:|---:|
| `inactive_to` | 30 m | **1 m** |
| `idle_after_inactive_to` | 30 m | **1 m** |
| `idle_to` | 1 h | **15 m** |
| `light_after_inactive_to` | 3 m | 1 m |
| `light_max_idle_to` | 15 m | 30 m |
| `max_idle_to` | 6 h | 6 h |
| `use_freezer` | **false** | **true**, `freeze_debounce_timeout=10000` |

Two things follow, and both are recorded as observations about these two images
rather than as claims about any phone.

1. **The natural Doze schedule differs by a factor of thirty between two
   platform versions on one host.** Any procedure that assumed a fixed
   time-to-Doze would mis-time most of the matrix. This is why §5.3 derives the
   waits from each device's own `dumpsys deviceidle`, and why `probe` commits
   that dump beside every run.
2. **The cached-apps freezer is off on the Android 11 image and on at Android
   15**, consistent with AOSP documenting the ten-second freeze for Android 14
   and higher. The mechanism this whole capability exists to defeat may
   therefore not exist on part of the fleet — Android 11 and 12 together are
   27.1% of it — and if a backgrounded socket dies there, it dies for some other
   reason. That is a question the `samsungAndroid11To12` and
   `xiaomiAndroid11To12` cells now have to answer explicitly, and neither has
   been run.

**Observed about the instrument, not about the capability** (emulator, API 35,
2026-08-23): every subcommand of `tool/measure_sustained_delivery.sh` was run
end to end against a package that was not this application — `probe`, `doze
--mode force` and `--mode release`, `watch` (four samples at 20 s, resolving the
application UID, Doze state, standby bucket and exemption correctly), `mark`,
and `verdict`, which printed each threshold beside its result. The instrument
works. That is a fact about the instrument and is not a result about sustained
delivery, which the instrument has never been pointed at.

#### The first hardware data point (Samsung A56, One UI 8.5, 2026-08-23)

Every item below is **observed**, once, on one phone, on one date. None of it is
a measurement of the capability, which was never started.

- **The procedure runs on retail Samsung hardware.** From an unrooted `adb
  shell` on a `release-keys` `user` build: `dumpsys deviceidle force-idle`
  answered *"Now forced in to deep idle mode"* and `get deep` then reported
  **`IDLE`** — so the forced arm of §5.3 is available on the cell that carries
  the most fleet weight. `am get-standby-bucket` returned a bucket,
  `/proc/net/tcp6` was readable (122 rows), `dumpsys notification --noredact`
  and `dumpsys deviceidle whitelist` both answered, and `dumpsys activity oom`
  reported this phone's process states. The device was returned to `ACTIVE`
  and charging immediately afterwards.
- **The vendor intent this application ships actually resolves.** ADR-051 took
  `com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY` on
  `com.samsung.android.lool` from Samsung's developer documentation, and nobody
  had ever confirmed it exists on a phone. On this device
  `cmd package resolve-activity` resolves it to
  `com.samsung.android.lool/com.samsung.android.sm.battery.ui.usage.CheckableAppListActivity`
  with `isDefault=true`. So the "Open my phone's settings" button goes
  somewhere real on One UI 8.5. It was **not pressed**: whether that screen is
  the right list, and whether excluding the app there changes anything, are
  behavioural questions this probe does not touch.
- **This phone's Doze schedule is nothing like the API 35 emulator's**, and the
  emulator was the faster one:

| Doze constant | A56 (One UI 8.5) | emulator API 35 | emulator API 30 |
|---|---:|---:|---:|
| `inactive_to` | **30 m** | 1 m | 30 m |
| `idle_after_inactive_to` | **30 m** | 1 m | 30 m |
| `idle_to` | **1 h** | 15 m | 1 h |
| `sensing_to` | **4 m** | 30 s | 30 s |
| `locating_to` | 30 s | 15 s | 15 s |
| `light_after_inactive_to` | 1 m | 1 m | 3 m |
| `max_idle_to` | 6 h | 6 h | 6 h |

  The consequence is concrete and was not previously written down anywhere in
  this repository: on this phone, natural deep Doze needs **30 minutes** of
  screen-off and stationary before the idle countdown even starts, then sensing
  and locating on top — so first deep `IDLE` is on the order of **35 minutes**,
  not the ~2 minutes the API 35 emulator would have suggested. Any C1–C4
  duration taken from that emulator would have been wrong by more than an order
  of magnitude. The API 30 emulator happens to match this phone; that is not a
  reason to trust either, it is a reason to keep reading the constants per
  device, which §5.3 already requires and `probe` already captures.
- **Whether the cached-apps freezer is active on One UI 8.5 could not be
  determined.** `dumpsys activity settings` prints no `use_freezer` on this
  device (the API 35 emulator prints `use_freezer=true` with
  `freeze_debounce_timeout=10000`), `device_config get
  activity_manager_native_boot use_freezer` returns `null`, and
  `/sys/fs/cgroup/uid_0/cgroup.freeze` does not exist — Samsung's cgroup layout
  differs. **This matters more than anything else here**: the freeze-then-
  terminate-sockets behaviour is the entire justification for the foreground
  service. It is not observable by configuration read on this phone, so it has
  to be answered behaviourally — does a backgrounded socket actually die — which
  is a run, not a probe, and has not been done.

#### Two defects in the instrument, found by contact with hardware

Both were fixed before anything was committed, and both are recorded because an
instrument nobody has pointed at real hardware is an instrument whose faults are
still ahead of it.

1. **`probe` would have committed the phone owner's installed-app list.** On an
   emulator `dumpsys deviceidle` is all system packages; on this phone its
   allowlist sections were **446 lines** naming the owner's own applications,
   including the seven they have battery-exempted. The harness now keeps only
   the `Flags:` and `Settings:` blocks and the trailing state booleans, and
   replaces every other section with its heading and a withheld-line count. The
   two emulator records were regenerated in the same format.
2. **`watch` was reading a field that does not exist.** It looked for `frozen=`
   in `dumpsys activity processes`; that field appears on **none** of the three
   devices — not One UI 8.5, and not either AOSP emulator — so it would have
   written the string `"unknown"` at every sample of every run while looking
   like data. That is this piece's own failure mode in miniature: a column that
   is always green because it is never measured. It now reads the adj label and
   state triple from `dumpsys activity oom` (verified on all three devices), and
   records `absent` when the process is not listed at all — which is the
   strongest failure the instrument can see.

**Everything else in §3 and §4: NOT RUN.**

### 6.2 What prevented it, exactly

1. **Five of the seven cells have no device.** No Xiaomi of any version, and no
   Pixel or AOSP hardware for the control cell. A Samsung A56 on Android 16 is
   available, which is the `samsungAndroid14Plus` cell; the two older Samsung
   cells need Samsung hardware on Android 11–13, which this phone is not and
   cannot be made into.
2. **The `platformReference` cell was substituted with an emulator, and the
   substitution does not answer the cell's question.** An emulator answers
   *"does AOSP behave as documented"*; the cell asks *"does this application's
   service survive on a device with no manufacturer layer, for 24 hours, with
   real Doze entry and a real radio"*. An emulator has no radio, no carrier NAT,
   no battery, and — the point of the control cell — no manufacturer to be
   distinguished from. It is recorded as a probe, marked `emulated`, and the
   admissibility rule in the gate refuses it automatically.
3. **The capability cannot be exercised at all — on the emulators or on the
   A56.** This is what blocks the one cell that now has hardware, and no device
   fixes it. `runSustainedDelivery` refuses any session that is
   not `AccountSessionScope.full` with `securitySetupComplete` and a `deviceId`,
   and the sustained-delivery screen sits behind the signed-in application shell.
   Reaching a signed-in state needs an activated account, and
   `backend/accounts/API.md` creates every account inactive, with activation a
   human action by the deployment's operator. So even *with* a device, the
   measurement additionally needs an operator-activated pair of test accounts,
   which do not exist. Nothing was installed on the A56: it is somebody's
   personal phone, and a development build could not have been signed into
   anyway. (A *beta* debug build must never be installed on a real phone at all
   — it claims the frozen beta application ID with a debug key, after which the
   genuine signed beta refuses to install over it and recovery is an uninstall
   that destroys local state.)
4. **The service cannot be started from outside the application either.**
   `SustainedDeliveryService` is `exported="false"`, so `adb shell am
   start-foreground-service` cannot reach it. That is a property the architecture
   test deliberately pins, and it is correct; it also means there is no
   shortcut around (3).

### 6.3 Measurement, inference, and neither

- **Measurements** (this run): the emulator observations and the Samsung A56
  observations in §6.1 — what those devices are, what they permit, this phone's
  Doze constants, and that the vendor intent resolves. Each is one reading on
  one device on one date, about the *device*, never about the capability.
- **Inferences**: that a foreground service prevents the freeze and the socket
  termination, and that the exemption preserves network through Doze and lifts
  the standby-bucket restrictions. Every one of those is drawn from Android's
  documentation (§9) and none has been observed here.
- **Neither**: whether Samsung or Xiaomi actually let this run. Samsung's One UI
  6.0 statement is a vendor's declaration of intent about a subset of its own
  devices, and having a One UI 8.5 phone in hand does not convert it into
  evidence — nothing was run on it. Xiaomi has published nothing about
  foreground services at all;
  `dontkillmyapp.com` is collected community evidence with no stated methodology,
  useful for knowing what to look for and load-bearing for nothing.

### 6.4 The strongest claim this evidence supports, in one sentence

*On a retail Samsung Galaxy A56 running Android 16 and One UI 8.5, and on two
AOSP emulator images, on 2026-08-23, every observation surface this procedure
depends on worked from an unrooted shell, that phone reaches forced deep Doze,
the Samsung settings intent this application ships resolves on it, and its real
Doze schedule is thirty times slower than the emulator this document had been
reasoning from — which establishes that the procedure is runnable on the
manufacturer that is half this fleet, and establishes nothing whatsoever about
whether sustained delivery works on that phone or any other, because it was
never started on one.*

### 6.5 The weakest link

**A Xiaomi device on Android 13 or 14 whose owner has not touched the autostart
setting.** It is roughly a fifth of the fleet on its own, the manufacturer has
published nothing about foreground services, its "Background autostart"
permission is off by default for sideloaded applications, and this application
is sideloaded by definition — it is never distributed through a store. Nothing in
this repository, and nothing this piece found, says what happens there.

---

## 7. The gate

**State: CLOSED.** Not partially evidenced. Closed.

### What it is

`lib/app/config/sustained_delivery_gate.dart` holds a compile-time constant
`SustainedDeliveryGate.releaseAssertion` carrying an evidence ledger, which is
**empty**. The gate is open only when **every** mandatory cell of §4 has an
**admissible** record.

### Where it bites

`sustainedDeliveryAvailabilityProvider` reads the compiled `AppEnvironment` —
fixed by the entry point, unselectable at runtime — and answers:

| Build | Answer | Effect |
|---|---|---|
| production (the build handed to people, [ADR-076](decisions.md)) | `withheld` | not offered |
| development | `measurementOnly` | offered, so the matrix can be run |

In a withheld build, `SustainedDeliveryController` publishes
`SustainedDeliveryStatus.withheld`, never attaches its authentication listener,
never reconciles, and refuses `enable()` before the platform is asked anything at
all — so no permission is requested, no system dialog is shown, no durable choice
is written, and the service is never started. It does one positive thing: it
**stops** a service an earlier build may have left running, because a permanent
notification must never outlive the decision to stand behind it. It does not
clear the user's durable choice, which is theirs and which a later evidenced
build is entitled to honour.

The connection policy consequently answers *no* in every distributed build, so
`SyncLifecycleSupervisor` closes its socket on backgrounding exactly as it did
before ADR-051.

### What a withheld artifact still declares

The manifest is shared by both flavours, so a withheld build still declares
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`,
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and the `SustainedDeliveryService` itself
— verified with `aapt2 dump badging` on the production release artifact built on
2026-08-23. All three permissions are normal protection level: granted at
install with no prompt, granting no data, no network and no location. The
service is `exported="false"`, so nothing outside the application can start it,
and inside the application nothing will: there is no switch, no reconciliation
and no enable path. The declaration is inert, and it is stated here rather than
stripped, because removing it would fork the manifest per flavour and make the
distributed artifact differ from the one the matrix is measured on — which is
the one thing this gate must not do.

### Exactly what would open it

Seven records in that ledger — one per cell — each of which must pass
`SustainedDeliveryFieldEvidence.isAdmissible`:

- `emulated` is **false**;
- `hardware` and `platformVersion` are non-empty, as the device reports them;
- `observedOn` is a real ISO date;
- `runRecord` names a committed run directory;
- `holdingHours` ≥ **24**;
- `deliveriesObserved` ≥ **20**;
- `repetitions` ≥ **3**.

A record failing any clause is not refused — it may be written down, and should
be — it simply **does not count**, so the cell stays outstanding. That is the
mechanism by which the gate cannot be satisfied by an emulator, by a short run,
by a single observation, or by a row somebody typed.

### Why it cannot be satisfied by assumption

- There is no environment define, no remote value, no runtime setter and no debug
  override; `test/architecture/sustained_delivery_gate_test.dart` fails if any
  appears.
- The same test asserts the ledger is empty, that production is withheld, that
  a full ledger of admissible records **does** open the gate (so
  the mechanism is demonstrably real, not decoration), and that an emulated,
  short, or under-repeated ledger opens nothing.
- It applies to the artifact users receive, not to a developer build: production
  is withheld by the same constant.
- It is discoverable: the constant, this document, the release checklist in
  `deployment-and-release.md`, `platform-android.md` and `docs/README.md` all
  name each other.

### What it costs that measurement needs a build users do not receive

The development flavour differs from the production flavour in its application ID,
its launcher label, its signing identity and its provisioning prefix. It is
**identical** in the `main` Android source set — the manifest,
`SustainedDelivery.kt`, `BackgroundDelivery.kt`, `MainActivity.kt` — in the
packaged native crypto profile, and in `minSdk`/`targetSdk`/`compileSdk`. So a
result measured on a development *release* build transfers to the production build
**for the Android platform mechanics**: service type, notification properties,
freezer behaviour, Doze survival, restart recovery, vendor deviation.

It does **not** transfer for: anything touching the provisioned origin's TLS path
or its certificate authority, and the behaviour of the frozen signing identity
across an upgrade. And it can never measure the production artifact's *gate*, only
its mechanics — a build with the gate open is by construction not the build users
get. Those limits are the price of being able to measure at all, and they are
stated rather than papered over.

---

## 8. Limitations of this validation, and when it expires

- The fleet is a **country panel statistic**, not this deployment's twenty-odd
  actual phones (§2.4). Follow-up F1.
- Statcounter's own series has two months that do not behave (§2.1). A panel that
  can move Apple's share by sixteen points in a month is not a precision
  instrument.
- C8 (vendor setting survives an OTA) **cannot be scheduled** and may never be
  observed. It is the criterion most likely to remain permanently open, and it is
  also the one whose failure mode is exactly this deployment's users: people who
  do not repeat setup and do not notice when an update undoes it.
- The four-minute keepalive is a documentation-derived compromise and has never
  been measured against an Iranian carrier's NAT.
- Battery and data cost are not measured by any criterion here. They should be,
  and are not, because they need hardware too.
- Nothing here covers Huawei, Honor, or Android 10 and below.

**Re-run conditions.** This result expires on the earliest of:

1. **2027-02-23**, six months from the fleet read. Android 16 gained fourteen
   points of share in a year; a version distribution six months stale is a
   different fleet.
2. Any new Android major version reaching material share in this country.
3. Any change to `specialUse`, the cached-apps freezer, the standby-bucket
   network rules, or the Doze-exemption implication for buckets.
4. Any change to the capability itself, its service type, its keepalive, or its
   reconciliation.
5. The user base ceasing to be 20–30 known people receiving a written handover.

---

## 9. Sources

All read **2026-08-23** unless stated. Official platform and vendor
documentation first; collected community evidence is labelled as such and
carries no conclusion.

| Source | URL | Page's own last-updated |
|---|---|---|
| Statcounter, mobile vendor share, Iran | <https://gs.statcounter.com/vendor-market-share/mobile/iran> | data through 2026-07 |
| Statcounter, Android version share, Iran | <https://gs.statcounter.com/android-version-market-share/mobile-tablet/iran> | data through 2026-07 |
| Doze and App Standby | <https://developer.android.com/training/monitoring-device-state/doze-standby> | 2026-08-18 |
| App standby buckets | <https://developer.android.com/topic/performance/appstandby> | 2026-08-14 |
| Power management resource limits | <https://developer.android.com/topic/performance/power/power-details> | 2026-05-19 |
| Cached apps freezer (AOSP) | <https://source.android.com/docs/core/perf/cached-apps-freezer> | 2026-06-17 |
| Foreground service types | <https://developer.android.com/develop/background-work/services/fgs/service-types> | 2026-08-14 |
| Foreground service timeouts | <https://developer.android.com/develop/background-work/services/fgs/timeout> | 2026-08-14 |
| Background-start restrictions | <https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start> | 2026-08-14 |
| Android 16 behaviour changes | <https://developer.android.com/about/versions/16/behavior-changes-all> | 2026-08-14 |
| Android 17 behaviour changes | <https://developer.android.com/about/versions/17/behavior-changes-all> | 2026-08-14 |
| Samsung, application management | <https://developer.samsung.com/mobile/app-management.html> | no date published |
| *Collected community evidence, no stated methodology* | <https://dontkillmyapp.com/samsung>, <https://dontkillmyapp.com/xiaomi> | — |

**What the platform actually says, in the three categories this project keeps
separate:**

- **Guaranteed (as restrictions).** "When an app process is frozen, all of its
  threads are suspended"; "If all processes for a particular app are frozen, the
  system terminates any active TCP sockets maintained by the app"; "App processes
  in the cached state are frozen 10 seconds after entering the cached state"
  (AOSP, Android 14+). Network is **Disabled** in the *rare* and *restricted*
  buckets, and **Restricted during doze** at device level (power-details).
- **Permitted.** App state "app process is running a foreground service" gives
  Network: **No restrictions** (power-details). `specialUse`: permission
  `FOREGROUND_SERVICE_SPECIAL_USE`, runtime prerequisites **None**, and no
  timeout — the 6 h/24 h cap covers `dataSync` and `mediaProcessing`, and
  `shortService` is capped tighter. "The user turns off battery optimizations for
  your app" is an enumerated exemption from the background-start restriction. An
  app is in the *active* bucket while it "Runs a long running foreground
  service". "Apps that are on the Doze exemption list are exempted from the App
  Standby Bucket-based restrictions." Android's acceptable-use table rates the
  exemption **Acceptable** for an "Instant messaging, chat, or calling app …
  [that] can't use FCM".
- **Declines to specify.** Whether a started foreground service is restarted
  after a low-memory kill; whether a persisted job survives an in-place upgrade;
  what any manufacturer does. Android 17 (API 37) adds no relevant
  foreground-service or network change — its background hardening is about audio
  — but does add "app memory limits based on the device's total RAM", which is a
  new pressure on a long-lived process and is recorded here for the next re-run.

**Vendor, first-party.** Samsung: applications unused "for about 3 days" enter
sleeping mode, where "Job, Alarm, and Foreground-service are restricted";
16 days reaches deep sleeping, where apps "only become active when the user opens
them"; the user's exclusion path is Settings > Device care > Battery > Background
usage limits, deep-linked by
`com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY` with `activity_type=2`;
and "since One UI 6.0, foreground services of apps targeting Android 14 will be
guaranteed to work as intended so long as they are developed according to
Android's new foreground service API policy." Samsung publishes **nothing** about
whether that exclusion survives a firmware update. Xiaomi publishes a
"Background autostart" permission and no statement about foreground services at
all.

**Collected community evidence, weighed and not relied on.**
`dontkillmyapp.com/samsung` reports that "even when you remove an app from the
restricted list, Samsung may re-add them later after a firmware update". If true,
that is precisely criterion C8, and precisely the failure this deployment's users
would never notice. The site publishes no methodology, no dates against
individual claims and no sample; it is recorded here as a **reason to test C8**
and as evidence for nothing.

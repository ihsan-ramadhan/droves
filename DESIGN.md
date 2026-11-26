# Droves design direction

Reading this as: a pocket console for one person's running agents, used
one-handed on a phone while walking, in a warm Material 3 language, dial
**ENERGY 2 / RHYTHM 2 / MOTION 2**.

## Identity

Droves is the trailhead, not the dashboard. The screen answers one question
before anything else: **which agent is waiting on me right now?** Everything
else is a level below it.

The motif is the **drover's tally**: a narrow left rail of counted marks, one
per running agent, with waiting ones marked by a filled rust notch. It appears
in the inbox, in the workspace list, and in each tab strip. It is the only
repeated gesture in the product, and it stays when the components around it
move to Material 3.

## Material 3 mapping

Material 3 provides the interaction grammar: tonal color roles, shape scale,
state layers, type scale, and predictive motion. Droves provides the accent
and the rhythm. No component is copied from a Google product screen.

- **Seed**: rust `#A8471F`, chosen because it already marks "needs you" in the
  product. The generated tonal palette keeps the same emotional temperature.
- **Primary**: rust, used for the current destination, active controls, and
  focus. It never marks working or done agents.
- **Tertiary**: Fraunces-led contrast for workspace and agent names, the
  ledger voice from the previous design.
- **Surface**: warm paper in light mode, warm charcoal in dark mode. Tonal
  surface containers replace one-off borders on cards and list groups.
- **Error**: a distinct brick red, reserved for destructive actions and
  failures, never for "waiting on you" status.
- **Terminal**: a separate ink-on-charcoal pane. Its colors stay fixed across
  themes so the terminal reads as a window cut into the paper.

The palette stays at 2 cores plus one accent and one error. Neutral surfaces,
outlines, and state layers come from the M3 scheme.

## Type

Material 3 roles map onto the existing faces:

- **Display/Headline/Title**: Fraunces for workspace and agent names, plus
  screen titles. The serif keeps the ledger quality and separates names from
  the interface chrome.
- **Body/Label**: Google Sans fallback to system sans for controls, settings,
  buttons, and navigation. Mono is no longer the default UI voice.
- **Mono**: IBM Plex Mono for terminal content, counts, paths, IDs, and
  compact status metadata only. Its tall x-height at small sizes is why it
  stays on a phone.
- **JetBrains Mono Nerd**: fallback for private-use glyphs from terminal
  titles and paths, so they do not render as boxes.

## Shape and elevation

- M3 shape scale replaces the old 3px/6px ledger radius: 4px for dense rows
  and chips, 12px for cards and panels, 16px for sheets and dialogs, full for
  FABs and status chips that are meant to read as pills.
- Tonal surface containers carry grouping. Hairlines remain only where a
  boundary is functional, such as the terminal pane edge.
- Elevation follows M3: surface tint and tonal layers for raised surfaces,
  no broad shadows and no glow.

## Motion

MOTION 2, Material 3 easing and durations:

- Destination and pane/tab switches are instant. A bottom navigation bar is a
  direct index, so a fade or slide makes a familiar action feel delayed. The
  selected state layer and indicator still animate at 200 ms inside the M3
  component; the body does not.
- State changes (loading, error, empty, status word) crossfade at 200 ms with
  standard easing. The crossfade names a new state, it does not decorate a tap.
- Dialog and bottom sheet: M3 entrance and exit curves, scrim fades at 150 ms.
- Refresh and fetch spinners: only while work is in flight, never for status.
- Reduced motion: `MediaQuery.disableAnimations` drops duration to zero and
  removes the slide. A working agent stays a static word, no pulsing dots.
- No looping decoration, no parallax, no motion longer than 5 seconds.

## Layout

- Phone: one column, 48dp minimum touch targets, M3 `NavigationBar` with five
  destinations (Inbox, Agents, Scout, Changes, Settings). Safe-area inset
  reserved.
- Tablet/desktop: M3 `NavigationRail` at 900px, same destinations, terminal
  and panes reflow into the available width.
- No nested scroll: each screen has one scroll owner; the terminal is the
  scroll container in its own screen.
- Workspace is reached through Inbox. Files, Git, Search, Terminal, Chat,
  Connections, and Scout details are reached from workspace or settings
  actions rather than competing for bottom-bar space.

# Droves — design direction

Reading this as: a pocket console for one person's running agents, used
one-handed on a phone while walking, dial **ENERGY 1 / RHYTHM 2 / MOTION 1**.

## Identity

Droves is the trailhead, not the dashboard. The screen answers one question
before anything else: **which agent is waiting on me right now?** Everything
else is a level below it.

The motif is the **drover's tally**: a narrow left rail of counted marks, one
per running agent, with the waiting ones marked by a filled notch. It appears
in the inbox, in the workspace list, and (smaller) in each tab strip. It is the
only repeated gesture in the product.

## Palette

Two cores, one accent and one error color, warm and paper-like rather than terminal-black.

| Token | Light | Dark | Reason |
|---|---|---|---|
| `ink` | `#1B1A17` | `#EDE8DE` | Primary text: warm near-black, not pure black |
| `paper` | `#F4EFE4` | `#151412` | Surface: unbleached paper, so the terminal pane reads as a window cut into it |
| `muted` | `#6E675C` | `#9A9184` | Secondary text and rules |
| `accent` | `#A8471F` | `#D9642F` | Rust: the one accent. Used only for "needs you" and the current position mark |
| `error` | `#9E2B25` | `#D9514A` | Destructive confirmations and stopping work already in progress |

No gradient anywhere. No glow. One accent, one place: a waiting agent.

## Type

- **Fraunces** (variable serif) for workspace and agent labels. A drover reads
  names, not headings; serif gives the list a ledger quality and keeps it from
  looking like every other dark terminal app.
- **IBM Plex Mono** for everything in a terminal, plus counts and paths.
  Chosen for its tall x-height at small sizes on a phone, not for "code vibes".

## Motion

MOTION 1: transitions only where state changes (pane focus, tab switch,
inbox row resolving to read). No looping animation, no pulsing dots. A working
agent's status is a static word, not a spinner.

## Layout

- Phone: one column, 44px minimum targets, bottom bar for the four destinations
  (Inbox, Agents, Changes, Settings). Safe-area inset reserved.
- Tablet/desktop: rail on the left, terminal on the right. The same widgets,
  reflowed at 900px.
- No nested scroll: the terminal is the scroll container in its own screen.

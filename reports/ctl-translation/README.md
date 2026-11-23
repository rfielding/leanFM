# Turning a protocol into pure CTL (an exercise for selfhost.session.ctl-translation)

`translate.py` turns a protocol's structure (sequence, choice and cause; not yet loops, `par`,
`sessions` or includes) into future-only CTL, then asks the running service's `session_ctl` to
decide every formula on the protocol itself and on broken variants of it (`cases.json`, every
variant itself a valid protocol). No past modalities: "B never before A" is `not E[not A U B]`.

Rules, each formula named by the messages it comes from:

| rule | formula |
|---|---|
| start | `AX` one of the first messages |
| succession (prev, lossless) | after the last message of a step, `AX` one of the next step's first messages |
| order (in-order) | `not E[not prev U next]` |
| cause | `not E[not request U answer]`, and `AG(request -> AF answer)` |
| choice | after a branch's first message, `AG not` any other branch's message |
| possible | `EF` every message |
| end | after a final message the session may end (`terminal`), and `AF terminal` |

Result (`report.json`):

| protocol | formulas | hold on it | broken variants caught |
|---|---|---|---|
| Orders | 17 | 17 | 4 of 4 |
| PlaceOrder | 40 | 40 | 3 of 3 |

- reordered (GetOrder first): start, succession, order and end are disproved
- an extra final message: only "after Order the session may end" is disproved
- a loop added: end ("may end" and "every session ends", since it can now run forever)
- outcomes swapped between the bank's branches: succession, order, choice and cause, ten formulas
- a message or branch removed (GetOrder dropped, no SoldOut, bank skipped): the formulas that name
  it are rejected, since the variant no longer has the message (so "it can happen" cannot hold)

What it shows: the structure's formulas hold on the protocol and pin it down for these variants.
`start`, `succession` and `end` (with `possible` for removals) carried every catch; `order` and
`cause` were implied by succession here and only matter once succession is weakened, which is
what a lossy or reordering channel does. Removals are caught only by vocabulary; a translation
meant to compare protocols should check "every message can happen" on both sides.

## Whole protocols: `translate_full.py`

`translate_full.py <example> <out.json>` extends the rules to loops, `par`, `sessions` and includes,
reading the structure from `session_explore`. The rules depend on where a message sits: the next step
(`AX`) and a certain answer (`AF`) only outside `par` (inside, another branch may move first, and without
fairness it may run forever); a branch excludes the others only outside loops; only labels that occur
once in the protocol say what came after what (a label such as `RequestRejected` only counts as an
answer); "can always end" (`AG EF terminal`) replaces "every session ends". On GoServer (`goserver.json`):
78 formulas, all 78 proved over its 10,969-state graph, in about 55 s at one call per formula.

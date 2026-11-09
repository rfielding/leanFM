# Chapter 12: inferred session types

Source: https://rfielding.github.io/leanFM-dark.pdf, chapter 12, pages 107–112; local LegalDepositExample.lean.
Prompt: "chapter 12 is a legal example... the Session Type is not written out. can you deduce it?"
Question: Which interaction grammar covers the four recorded histories, and is it projectable?
Event source: LegalDepositExample.lease, compliant, late, lost, mercy.
Reducer: factor common prefixes and retain message directions and explicit causes; session_check and session_review.
Unit: ordered protocol events, not elapsed time.
Boundary: four finite examples of one tenancy; not a complete tenancy protocol or a proof of normative compliance.

Update: DepositHistories.leanfm now includes a later direct resend after BelievesViolated. Both session_check and session_review pass. The original lost-letter history conforms only as an incomplete prefix; a complete history must continue with ForwardingAddress and settlement. This is an explicit recovery assumption, not an event asserted to have occurred within the chapter's recorded history. See validation.json for seven positive and negative conformance checks. The historical findings below explain the initial reconstruction.

The original candidate grammar produced this session_check report:
Landlord cannot tell which branch Tenant chose.
After LeaseEnded, the tenant may send an address to the landlord, or send a letter to Post and record a belief. The lost branch supplies the landlord no distinguishing message. Ending this branch models the recorded observation horizon, not a confirmed end of the tenancy interaction. Do not insert a delivery/loss notification just to pass the check: the source provides none.

Each protocol in Scenarios.leanfm was independently checked with session_check: all four pass. They are scenario-specific session types, not proof that their combined choice is projectable.

Inference qualifications:
- Finite traces do not uniquely determine a global type. Unseen alternatives, loops and concurrent orderings cannot be recovered uniquely.
- These scenario types serialize the listed interactions. DepositProtected and LeaseEnded do not have a direct predecessor relation in the source; this is one ordering, not evidence of a required dependency.
- HardshipRequest (day 330) and RentOffsetAgreed (day 332) were moved before LeaseEnded (day 365), matching timestamps and predecessor constraints. The original mercy.events list appends them after the common lease prefix that already includes LeaseEnded.
- BelievesViolated is represented as a Tenant local event instead of a Tenant-to-Tenant message.
- Dates, amounts, deductions, address knowledge and normative judgments remain outside this message-order projection.
- The Act and the moral code classify admissible runs; they must not remove violations from the grammar.
- The local act2 evaluator checks DepositReturned, not DeductionsItemized independently. Both occur on day 372 in the itemised example, masking that gap relative to section 12.2.
- Loss is absence of delivery in the bounded recorded history. No deadline detector, delivery acknowledgment, claim rejection or optional abandonment behavior is specified.

A full protocol needs explicit observation horizons/timeouts or asynchronous service boundaries and additional possible behavior. The chapter does not settle those choices.


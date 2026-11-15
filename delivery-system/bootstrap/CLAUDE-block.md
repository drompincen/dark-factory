<!-- delivery-system:start (written by "dq install"; edit the source, not this copy) -->
## Delivery system

This workspace delivers Jira tickets through the proof-driven delivery
system. It lives in: {{SYSTEM_DIR}}

- At the start of every session, before any other work, read
  {{SYSTEM_DIR}}/DELIVERY-AGENT.txt and run its start routine. If the
  engineer has not named a ticket, ask for the Jira epic or story key.
- Call the coordination tool by this exact path: {{SYSTEM_DIR}}/tools/dq
- Never start work on a ticket until "dq claim" has succeeded for it.
- Never force-push, never push to a default branch, never delete a remote
  branch.
<!-- delivery-system:end -->

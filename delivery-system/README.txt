PROOF-DRIVEN DELIVERY SYSTEM
============================
Version 0.3

This directory is everything a Claude Code session needs to take a Jira
epic or story and deliver it with proof, alongside several hundred other
sessions, using only git and read-only Jira.

Copy the whole directory into a shared repo that every workspace can
clone. Sessions read it from there, and "dq version --check" keeps every
copy on the same version.


WHAT IS HERE
------------

  DELIVERY-AGENT.txt     The core manual. Every session reads it at the
                         start. 220 lines.
  manual/                Read when needed:
    CONCEPTS.txt           what the words mean, and a map into the spec
    SETUP.txt              first run in a workspace
    DELIVER.txt            from a Jira key to proof, step by step
    COORDINATE.txt         claims, heartbeats, handover, tracks, waiting
    TEMPLATES.txt          every file a session writes
  proof-driven-delivery-system.txt
                         The spec: why the system is shaped this way.
  tools/dq               The coordination tool. One bash script; needs
                         bash 4, git 2.20 and the usual core utilities.
                         python3 is used when present, for JSON.
  tools/selftest.sh      Runs dq against throwaway repos. Run it once in
                         your environment before relying on dq.
  templates/             The files a session writes.
  environment.example.yaml
                         Copy to environment.yaml and fill in once.
  bootstrap/             The block "dq install" adds to CLAUDE.md, and the
                         settings to merge by hand if python3 is missing.
  skills/                Three thin skills: deliver, delivery-setup,
                         look-around. "dq install" copies them in.
  VERSION, CHANGELOG.txt


ONCE, BY THE HARNESS TEAM
-------------------------

 1. Put this directory in a shared repo. In environment.yaml, set
    system.remote and system.path_in_repo.
 2. Run tools/selftest.sh on a coder workspace. It should end with
    "0 failed". If it does not, the failing lines say which git or shell
    behaviour differs in your environment.
 3. Create the queue repo. Protect these branch patterns so that
    developers can push and nobody can force-push:
        claim/*   lease/*   evidence/*   request/*   config/*   board
    Protect the default branch so that it changes only by merge request.
    This is the lock the whole system rests on. A session verifies it
    during setup with "dq protect-check".
 4. Make sure pushes to those branches start no pipelines: set
    queue.push_options to ci.skip in environment.yaml, or exclude the
    patterns in the queue repo's pipeline rules. A heartbeat is a push,
    and there will be thousands a day.
 5. Fill in environment.yaml: where Atlas and the queue are, how Jira is
    read, how spotlights start, the track names, what makes a track
    deploy, where results come back, and the Atlas page that maps Jira
    projects and components to remits. Every answer written here is one
    that fifty engineers are not asked.
 6. Schedule the board job, every few minutes. It needs a clone of the
    queue repo, a copy of this directory, and a token that may push to
    the "board" branch. It needs no config file:
        DQ_QUEUE=<queue clone> DQ_ENGINEER=board-job tools/dq board --publish
    It writes one branch, "board", that every session reads in place of
    hundreds of claim branches. BOARD.md on that branch is the page people
    open to see who holds what, open questions, quiet claims, tracks and
    requests.
 7. Decide how a finished item closes (queue.close_method): by merge
    request from claim/KEY to the default branch, or by a pipeline that
    does the same. After the merge, archive the claim branch from the
    server side. Sessions never delete branches.
 8. Decide where large evidence goes (evidence.location): the evidence/KEY
    branches, or a shared directory.
 9. Decide who posts Jira comments (jira.mirror). Sessions cannot write to
    Jira. Each item keeps a ready-to-post comment in jira-update.md; a job
    with Jira write access can post it at each state change, or the
    engineer pastes it.
10. If tracks are leased through git (tracks.lease_method: branch), make
    the track pipeline refuse a deploy from an item that does not hold the
    lease. The lease is lease/TRACK:lease.yaml on the queue repo.
11. Watch the requests on the board. Each one is a session saying what it
    could not do.


ONCE PER WORKSPACE, BY THE ENGINEER
-----------------------------------

    git clone <system.remote> <somewhere>
    <somewhere>/<path_in_repo>/tools/dq install --workspace <workspace root>

That adds a short block to the workspace's CLAUDE.md, three skills, two
hooks and a few permission rules, and drops an empty delivery.config.yaml.
Then start Claude Code in the workspace and say "start". The first session
runs setup: it reads environment.yaml, asks what is still unknown, and
proves each capability by using it.


EVERY SESSION
-------------

Start Claude Code in the workspace. Say "start", or name the work:
"Deliver PAY-1423". With no ticket named, it asks for the Jira epic or
story.


WHAT IS NOT PROVEN YET
----------------------

- dq is tested against plain git on Linux (tools/selftest.sh). It has not
  run against your GitLab, your branch protection or your pipelines.
  Step 2 and "dq protect-check" are how you find out.
- The Claude Code settings that "dq install" writes (hooks, permission
  rules, the unattended mode) follow the public documentation as of
  November 2026. Check them against the version you run.
- The manual has not yet been followed end to end by a session in your
  environment. Expect the first few items to show what it gets wrong. Fix
  the manual in the shared repo, raise VERSION, and add a line to
  CHANGELOG.txt; every session picks it up at its next start.

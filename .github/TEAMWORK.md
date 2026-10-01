# Teamwork notifications

No GitHub Project or GitHub issue is required. The integration uses
[Teamwork/github-sync](https://github.com/Teamwork/github-sync), pinned to commit
`9778e6e09b34abaca4f107d2cbd43a9f72337de0`.

## Repository setup

Add these repository Actions secrets (Settings > Secrets and variables > Actions):

- `TEAMWORK_URI`: the Teamwork site URL, e.g. `https://company.teamwork.com`.
- `TEAMWORK_API_TOKEN`: an API key for a Teamwork user with access to the target tasks.
  Comments are posted as this user; the action enables task notifications.

Install `.github/workflows/teamwork-production-merge.yaml` on the `Production`
branch in each consuming repository. Include `.github/pull_request_template.md`
to prompt authors for the task links. This template repository uses `main`;
merging into `main` does not send production notifications.

If a consuming repository uses a different production branch name, update the
workflow's `branches` filter to that exact name.

## PR and commit workflow

- Keep the functional task in Teamwork. A task code in commits is optional for
  traceability and is not parsed by this action.
- Add the full Teamwork URLs to the PR body, one per task and without duplicates.
  Supported links contain `/tasks/` followed by the numeric task ID, for example
  `https://company.teamwork.com/app/tasks/123456`.
- For a promotion/release PR, copy all relevant task links from its feature PRs.
  The action does not discover tasks through commits, issues or earlier PRs.
- On a merge into `Production`, the action comments on every linked task with
  the PR title, PR URL and merge author. A closed, unmerged PR does not notify.
  A PR with no task links produces no Teamwork comments.
- Tags and workflow-stage changes are disabled. Tasks remain open.

The repository settings map `Production` to `BCBE-LIVE` and `Accept` to
`BCBE-UAT`, with continuous deployment disabled. Publication is started manually
through `PublishToEnvironment.yaml`. This notification therefore means
**merged into the production branch**, not **deployed to Business Central**.
Do not add the PR action to the publish workflow: it expects a pull-request event.

## Validation and limitations

Run `actionlint .github/workflows/teamwork-production-merge.yaml` for static
workflow validation. For an end-to-end check, use a test Teamwork task and a PR
into the configured production branch; verify the comment, then verify that a
closed, unmerged PR and a PR to `Accept` do not notify.

The upstream action can create duplicate comments when a workflow is rerun and
does not consistently fail on HTTP errors. Inspect the Teamwork task to confirm
delivery. Missing repository secrets or inaccessible tasks prevent delivery.

The action has no integration subscription fee. Standard GitHub-hosted runner
minutes for private repositories count toward the existing GitHub Actions quota.

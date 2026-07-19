# Basic Installations

Step-by-step installation guides for learners. Each guide assumes no prior experience, spells out every command, states what output to expect, and includes a troubleshooting section for the errors people actually hit.

## Guides

| Guide | What it covers | Cost |
|-------|----------------|------|
| [Flask Installation Guide](./flask_installation_guide.md) | Installing Flask on Windows, WSL, and macOS | Free |
| [Jenkins on AWS EC2 — Manual Deployment](./jenkins_ec2_deployment_guide.md) | Deploying Jenkins on an EC2 instance from the AWS Console and accessing it securely | ~$1/day while running — **clean up when done** |

## Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/install-jenkins.sh`](./scripts/install-jenkins.sh) | Installs Java 21 + Jenkins LTS on Ubuntu. Works as EC2 user data or run by hand. |
| [`scripts/verify-jenkins.sh`](./scripts/verify-jenkins.sh) | Health check for a Jenkins install, with a fix hint for each failure. |

## For instructors

The Jenkins guide is self-contained and can be shared on its own. Two things worth flagging to learners up front:

- **Instance type depends on the learner's account.** Jenkins needs 4 GB RAM, so `t2.micro` is not viable. Accounts on AWS's newer Free Tier plan *refuse* to launch `t3.medium` at all — those learners must use `c7i-flex.large` (4 GB, free-tier eligible). Expect this to split the room; the guide covers both.
- **Part 2 (the IAM role) is where most learners get stuck.** Without it there is no way into the instance at all. Consider walking through it together.
- Part 7 covers cleanup and should not be skipped — a forgotten instance bills ~$1/day.

### Known upstream gotcha

Jenkins rotates its apt signing key every few years and the old key **expires**. `jenkins.io-2023.key` — still quoted by the official docs and most tutorials online — expired on **2026-03-26**, so any guide using it now fails with `NO_PUBKEY` and Jenkins cannot install. `scripts/install-jenkins.sh` detects the current key automatically. If learners follow instructions from elsewhere and hit this, that is the cause.

## Verification status

The Jenkins guide was tested end to end against a real AWS account on **2026-07-19**: instance launch, user-data bootstrap, SSM shell, port forwarding, and unlocking the wizard. Jenkins **2.568.1** on Ubuntu 24.04 with Java 21.

Not verified: the AWS Console UI wording in Parts 1–2 (button labels and menu paths), which was written from the console flow but confirmed only via CLI equivalents. AWS changes console labels periodically — if a label has drifted, the surrounding step still describes the right action.

# Jenkins on AWS EC2 — Manual Deployment Guide

Deploy Jenkins on an AWS EC2 instance by hand, from the AWS Console, and open it in your own browser. Every click and command is spelled out. No prior AWS experience assumed.

By the end you will have a running Jenkins server that only **you** can reach.

> **Tested end to end on 2026-07-19** against a real AWS account: Jenkins **2.568.1** on Ubuntu 24.04 with Java 21, reached over an SSM tunnel at `localhost:8080`.
>
> The AWS Console *labels* in Parts 1–2 (button names, menu paths) are the one thing not machine-verified — AWS renames these occasionally. If a label has moved, the step still describes the right action.

---

## Before You Start

### What this costs

Jenkins needs about 4 GB of RAM. The old free-tier favourite `t2.micro` has 1 GB — it will boot and then crawl or crash. Which instance type you should pick depends on **which kind of AWS account you have**.

### If your AWS account is on the new Free Tier plan

Accounts created from roughly mid-2025 onward are on AWS's newer Free Tier plan, which **refuses outright** to launch instance types that are not free-tier eligible. You will get:

```
InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
```

On those accounts, use one of these instead — both are free-tier eligible **and** have enough memory:

| Instance | Memory | Notes |
|----------|--------|-------|
| `c7i-flex.large` | 4 GB | The minimum that works comfortably. **Verified working for this guide.** |
| `m7i-flex.large` | 8 GB | More headroom if you plan to run real builds |

Check what your own account allows:

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,MemoryInfo.SizeInMiB]' --output table
```

### If your account is a normal (paid) account

| Item | Choice | Rough cost (us-east-1) |
|------|--------|------------------------|
| Instance | `t3.medium` (2 vCPU, 4 GB) | ~$0.042/hour ≈ **$1.00/day** |
| Instance | `t3.large` (2 vCPU, 8 GB) — for real builds | ~$0.083/hour ≈ **$2.00/day** |
| Storage | 30 GB gp3 root volume | ~$2.40/month |

**Start with `t3.medium`.** A few hours of learning costs well under a dollar.

> **Do not skip Part 7 (Cleanup).** An instance left running for a forgotten month is roughly $30. Stop or terminate it when you finish for the day.

### What you need

- An AWS account with permission to create EC2 instances and IAM roles
- A web browser — that alone is enough for Parts 1–3
- For Part 4, **one** of:
  - AWS CLI v2 + Session Manager plugin on your machine (the secure route), **or**
  - nothing extra, if you use the simpler Option B in Part 4

### Time

About 40–60 minutes the first time. Most of it is waiting for AWS and `apt`.

### Key terms, in plain language

| AWS thing | What it actually is | Everyday analogy |
|-----------|--------------------|------------------|
| **EC2 instance** | A computer you rent by the hour in Amazon's data center | Renting a PC in someone else's building |
| **AMI** | The operating system image the computer boots from | The Ubuntu install disc |
| **EBS volume** | The virtual hard drive attached to it | The disk where files live |
| **Security group** | A firewall listing who may connect | A bouncer with a guest list |
| **IAM role** | An identity badge the computer wears, so AWS trusts it | A staff ID badge — nothing to lose or leak |
| **Session Manager (SSM)** | A secure remote-control channel run by AWS | A locked service tunnel into the building |
| **User data** | A script AWS runs the first time the computer boots | A setup wizard that runs itself |

---

## The Plan

```
Part 1  Launch an Ubuntu instance from the console
Part 2  Give it an IAM role so you can get a shell without SSH
Part 3  Install Jenkins (automatic, or by hand)
Part 4  Reach Jenkins from your browser
Part 5  Unlock Jenkins and create your admin user
Part 6  Troubleshooting
Part 7  Cleanup — stop paying
```

---

## Part 1 — Launch the Instance

### Step 1: Pick a region

Top-right of the AWS Console, choose a region near you (e.g. `us-east-1`). Everything you create lives in that region — if your instance "disappears" later, you are almost certainly looking at the wrong region.

### Step 2: Start the launch wizard

Go to **EC2 → Instances → Launch instances**.

Name it: `jenkins-lab`

### Step 3: Choose the operating system

Under **Application and OS Images**, select **Ubuntu**, then **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type**, architecture **64-bit (x86)**.

> The install script in this guide targets Ubuntu. Amazon Linux uses different package commands and the script will refuse to run.

### Step 4: Choose the size

Under **Instance type**, pick:

- **`c7i-flex.large`** if your account is on the new AWS Free Tier plan (see "What this costs" above)
- **`t3.medium`** if you have a normal paid account

> Do not use `t2.micro`. Jenkins plus Java will exhaust 1 GB of RAM and the service will die on you mid-setup, which is a miserable way to learn.

> If the console greys out your choice, or a CLI launch fails with `not eligible for Free Tier`, your account is on the restricted Free Tier plan — switch to `c7i-flex.large`.

### Step 5: Key pair — choose "Proceed without a key pair"

In the **Key pair (login)** dropdown, select **Proceed without a key pair (Not recommended)**.

Ignore the scary label. You are not going to use SSH at all — you will use Session Manager, which is *more* secure, not less.

> **Why this is safer:** an SSH key is a secret file that can be copied, emailed, or committed to Git by accident. No key means nothing to steal, and no port 22 open to the internet for bots to hammer.

### Step 6: Network settings — keep everything closed

Click **Edit** next to Network settings.

- **Auto-assign public IP**: Enable
- **Firewall (security groups)**: Create security group, name it `jenkins-lab-sg`
- **Remove every inbound rule.** Delete the default SSH rule if it is there.

You want **zero inbound rules**. Outbound is open by default, which is all you need.

> **In plain terms:** you are telling the bouncer "nobody gets in from the street." You will still get in — through the staff tunnel in Part 4, not the front door.

### Step 7: Storage

Change the root volume from 8 GB to **30 GB**, type **gp3**.

> Jenkins stores build history, workspaces, plugins, and artifacts. The default 8 GB fills up faster than you would think, and a full disk breaks Jenkins in confusing ways.

### Step 8: User data — install Jenkins automatically

Expand **Advanced details** (near the bottom), scroll to the **User data** box at the very end.

Paste the **entire contents** of [`scripts/install-jenkins.sh`](./scripts/install-jenkins.sh) into that box.

Three things that matter:

1. Paste the **whole file, including the first line** `#!/usr/bin/env bash`. Without that first line AWS silently ignores your script and nothing gets installed.
2. Do **not** paste it base64-encoded. The console does that for you.
3. Leave the "User data has already been base64 encoded" checkbox **unchecked**.

> **What user data is:** a script AWS runs once, as root, the first time the machine boots. It saves you from typing the install commands yourself.

*(You can skip this step and install by hand in Part 3 instead. Skipping is a perfectly fine way to learn what the script does.)*

### Step 9: Do not launch yet

Leave this tab open. You still need to attach the IAM role in Part 2 — and it is far easier to do it now than after launching.

---

## Part 2 — The IAM Role (the step everyone forgets)

Without this role, you will have a running server you cannot get into at all — no SSH key, no open ports, no shell. This is the single most common way this lab goes wrong.

### Step 1: Create the role

Open a **new browser tab** (keep the launch wizard open) and go to **IAM → Roles → Create role**.

1. **Trusted entity type**: AWS service
2. **Use case**: EC2 → select **EC2**
3. Click **Next**
4. In the permissions search box, type `AmazonSSMManagedInstanceCore` and **tick its checkbox**
5. Click **Next**
6. **Role name**: `jenkins-lab-ssm-role`
7. Click **Create role**

> **What this does:** it gives the instance permission to register itself with AWS Systems Manager. That registration is what makes the secure shell and the tunnel possible.

### Step 2: Attach it to your instance

Back in the launch wizard tab:

**Advanced details → IAM instance profile** → click the refresh icon → select **`jenkins-lab-ssm-role`**.

### Step 3: Launch

Click **Launch instance**.

**Expected after 1–2 minutes:**

- **EC2 → Instances** shows your instance as **Running**, Status checks **2/2 passed**
- **Systems Manager → Fleet Manager** lists your instance as **Managed**

That second one is the real test. If the instance never appears in Fleet Manager after ~3 minutes, the IAM role is wrong — see Part 6.

> **Already launched without the role?** You do not have to start over. Select the instance → **Actions → Security → Modify IAM role** → pick the role → Save. Then **Actions → Instance state → Reboot**. It will appear in Fleet Manager a minute or two after boot.

---

## Part 3 — Install Jenkins

### Step 1: Get a shell on the instance

The easiest way needs nothing installed on your machine:

**EC2 → Instances → select your instance → Connect button → "Session Manager" tab → Connect**

A terminal opens in your browser. That is a real root-capable shell on the server.

> If the **Connect** button on the Session Manager tab is greyed out, the instance is not registered with SSM yet. Wait two minutes, then re-check the IAM role from Part 2.

<details>
<summary>Alternative: connect from your own terminal (needs AWS CLI + plugin)</summary>

```bash
aws ssm start-session --target <INSTANCE_ID>
```

`<INSTANCE_ID>` looks like `i-0abc123def4567890` — copy it from the EC2 console.

This requires [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). You will need both anyway for Option A in Part 4.
</details>

### Step 2: Check whether user data already did the work

If you pasted the script in Part 1 Step 8, Jenkins may already be installed. Check:

```bash
sudo systemctl status jenkins --no-pager
```

**If you see `active (running)`** — done, skip to Part 4.

**If you see `Unit jenkins.service could not be found`** — the script did not finish. This is common; see Step 4 below to diagnose it. It is not something you did wrong.

**If you skipped Step 8 entirely** — continue to Step 3.

### Step 3: Install by hand

If the script was staged by a partial run, just re-run it:

```bash
sudo bash /opt/jenkins-install/install-jenkins.sh
```

If that file does not exist, download the script fresh:

```bash
curl -fsSL https://raw.githubusercontent.com/cloud-prakhar/basic-installations/main/scripts/install-jenkins.sh -o install-jenkins.sh
sudo bash install-jenkins.sh
```

> This only works once the repository is public. If it is private, use the paste method below instead.

Or paste it in directly. Type `cat > install-jenkins.sh << 'ENDOFSCRIPT'`, paste the whole file, then type `ENDOFSCRIPT` on its own line and press Enter:

```bash
cat > install-jenkins.sh << 'ENDOFSCRIPT'
#!/usr/bin/env bash
... paste the entire script here ...
ENDOFSCRIPT

sudo bash install-jenkins.sh
```

**This takes 3–6 minutes.** It prints its progress through four steps. At the end it prints your unlock password — **copy that somewhere**, you need it in Part 5.

### Step 4: If the automatic install failed, find out why

Run these on the instance:

```bash
# Did AWS run your user data at all, and did it succeed?
cloud-init status --long

# The install script's own log (only exists if the script started)
sudo tail -50 /var/log/jenkins-bootstrap.log

# AWS's record of everything user data printed — the authoritative log
sudo tail -80 /var/log/cloud-init-output.log
```

Match what you see against this table:

| What the log shows | What happened | Fix |
|--------------------|---------------|-----|
| `Could not get lock /var/lib/dpkg/lock-frontend` | Ubuntu's background updater was holding the package lock at boot | Just re-run the script (Step 3). It waits for the lock. |
| `Could not resolve 'pkg.jenkins.io'` | The instance has no outbound internet | Check the subnet has a route to an internet gateway and the security group allows outbound |
| No mention of the script anywhere | User data was never pasted, or the `#!/usr/bin/env bash` first line was missing | Install by hand (Step 3) |
| `Cannot allocate memory` / process killed | Instance too small | Stop the instance, **Actions → Instance settings → Change instance type** → `t3.medium` (or `c7i-flex.large` on a Free Tier account), start it again |

### Step 5: Verify before touching your browser

The quickest check is by hand:

```bash
systemctl is-active jenkins          # expect: active
java -version                        # expect: openjdk version "21...
curl -I http://localhost:8080/login  # expect: HTTP/1.1 200 OK  or  403 Forbidden
```

> **A `403` here is success, not failure.** It means Jenkins is running and asking for authentication. Only "connection refused" is a problem.

For a fuller check with a fix hint for each failure, copy [`scripts/verify-jenkins.sh`](./scripts/verify-jenkins.sh) onto the instance the same way you copied the installer, then:

```bash
sudo bash verify-jenkins.sh
```

**If the service is active but `curl` says connection refused:** Jenkins takes another 30–90 seconds to finish starting after the service comes up. Watch it with `sudo journalctl -u jenkins -f` and wait for the line `Jenkins is fully up and running`. Press `Ctrl-C` to stop watching.

### Step 6: Get your unlock password

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Copy the 32-character string. You need it in Part 5.

---

## Part 4 — Reach Jenkins From Your Browser

Jenkins is running on the server's port 8080, but that port is closed to the world. There are two ways in.

### Option A — SSM port forwarding (recommended, keeps everything closed)

Nothing about your security group changes. Traffic goes through AWS's encrypted tunnel.

**Requires** AWS CLI v2 and the Session Manager plugin installed on your machine:

- [Install AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Install the Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

Verify both, and that your credentials work:

```bash
aws --version
session-manager-plugin
aws sts get-caller-identity
```

Then start the tunnel — **in a terminal on your own machine, not on the instance**:

```bash
aws ssm start-session \
  --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

**Windows Command Prompt** needs different quoting:

```cmd
aws ssm start-session --target <INSTANCE_ID> --document-name AWS-StartPortForwardingSession --parameters "{\"portNumber\":[\"8080\"],\"localPortNumber\":[\"8080\"]}"
```

**Expected output:**

```
Starting session with SessionId: ...
Port 8080 opened for sessionId ...
Waiting for connections...
```

**Leave that terminal open — it *is* the tunnel.** Closing it or pressing `Ctrl-C` closes your access. Open a new terminal tab for anything else.

Now browse to:

```
http://localhost:8080
```

> **What just happened:** your laptop's port 8080 is now a private doorway. Traffic to `localhost:8080` travels through the encrypted AWS tunnel to the server's port 8080 and back. To your browser it feels local; in reality Jenkins is in the cloud, and nobody on the internet can reach it.

### Option B — Open port 8080 to your own IP only (simpler, less secure)

If you cannot install the CLI and plugin, you can open the port — **to your own IP address only, never to the world**.

1. Find your public IP: visit [whatismyip.com](https://www.whatismyip.com/) or run `curl ifconfig.me`
2. **EC2 → Instances → your instance → Security tab → click the security group**
3. **Edit inbound rules → Add rule**
   - Type: **Custom TCP**
   - Port range: **8080**
   - Source: **My IP** (the console fills in your address as `x.x.x.x/32`)
   - Description: `Jenkins temporary lab access`
4. **Save rules**
5. Copy the instance's **Public IPv4 address** from the EC2 console
6. Browse to `http://<PUBLIC_IP>:8080`

> **Never set the source to `0.0.0.0/0`.** An unauthenticated Jenkins open to the internet gets found and cryptomined within hours — this is a real and routine occurrence, not a hypothetical.

> Your home IP address usually changes every few days. If access stops working later, re-run step 3 and update the rule to your new IP.

> **Remove this rule when you finish the lab.** It is in the cleanup checklist in Part 7.

---

## Part 5 — Unlock Jenkins

You should now see the **Unlock Jenkins** page.

### Step 1: Paste the password

Paste the 32-character string from Part 3 Step 6 and click **Continue**.

Lost it? Get it again from an SSM shell:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### Step 2: Install plugins

Click **Install suggested plugins**. This takes 3–5 minutes and the progress screen looks frozen at times — let it finish.

> If plugins fail to download, the instance cannot reach `updates.jenkins.io`. Check outbound internet access — same fix as the DNS row in Part 3 Step 4.

### Step 3: Create your admin user

Fill in username, a **real password**, full name, and email. Click **Save and Continue**.

> Do not use `admin`/`admin`. Even behind a tunnel, get in the habit now.

### Step 4: Instance configuration

Accept the suggested Jenkins URL and click **Save and Finish**, then **Start using Jenkins**.

**You are done.** You should see the Jenkins dashboard.

### Step 5: Prove it works — run a job

1. **New Item** → name it `hello-world` → choose **Freestyle project** → **OK**
2. Scroll to **Build Steps** → **Add build step** → **Execute shell**
3. Enter:
   ```bash
   echo "Hello from Jenkins on EC2"
   date
   hostname
   ```
4. **Save** → **Build Now**
5. Click build **#1** in the build history → **Console Output**

You should see your text, the date, and the server's hostname, ending with `Finished: SUCCESS`.

---

## Part 6 — Troubleshooting

### `Unit jenkins.service could not be found`

This means the Jenkins **package was never installed** — the service file ships inside the package. It is not a broken service; there is no service.

Go to Part 3 Step 4 to find out why the install did not finish, then re-run the installer.

### `NO_PUBKEY` / "The repository is not signed"

Full error:

```
W: GPG error: https://pkg.jenkins.io/debian-stable binary/ Release:
   The following signatures couldn't be verified because the public key is not available: NO_PUBKEY ...
E: The repository 'https://pkg.jenkins.io/debian-stable binary/ Release' is not signed.
```

**Jenkins rotates its package-signing key every few years, and the old key expires.** The key most guides on the internet still tell you to download — `jenkins.io-2023.key` — **expired on 2026-03-26**. Anything built on those instructions now fails here.

The installer in this repo handles it automatically: it tries the current year's key first and skips any key that reports as expired. If you are following instructions from elsewhere, replace the key URL with the current one:

```bash
sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  -o /usr/share/keyrings/jenkins-keyring.asc
```

Confirm the key you downloaded is not expired — validity `e` in the second column means expired:

```bash
gpg --show-keys --with-colons /usr/share/keyrings/jenkins-keyring.asc | grep ^pub
```

### `apt update` keeps failing after a first failed install attempt

If an earlier attempt added the Jenkins repository but its key was never installed correctly, that broken entry breaks **every** subsequent `apt update` — including ones that have nothing to do with Jenkins. The symptom is confusing because the error persists even after you fix the key.

Clear the Jenkins repo and start again:

```bash
sudo rm -f /etc/apt/sources.list.d/jenkins.list /usr/share/keyrings/jenkins-keyring.asc
sudo apt-get update
sudo bash install-jenkins.sh
```

(The installer in this repo now does this cleanup itself on every run.)

### `not eligible for Free Tier` when launching

Your account is on AWS's newer Free Tier plan, which blocks non-eligible instance types outright. Use `c7i-flex.large` (4 GB) or `m7i-flex.large` (8 GB) — see "What this costs" at the top.

### Instance is not listed in Systems Manager / Fleet Manager

Nearly always the IAM role. Check, in order:

1. **EC2 → your instance → Security tab** — is there an IAM role attached at all?
2. **IAM → Roles → your role → Permissions** — does it have `AmazonSSMManagedInstanceCore`?
3. Did you reboot after attaching the role? Attaching it to a running instance needs a reboot to take effect.
4. Can the instance reach the internet? A subnet with no internet gateway route cannot reach the SSM service.

### `TargetNotConnected` when starting a session

Same causes as above. Also: wait a full 2–3 minutes after boot — the SSM agent registers a little after the instance reports "running".

### Browser says "connection refused" at localhost:8080

- Is the tunnel terminal still open? Closing it closes access.
- Is Jenkins actually up? Check on the instance: `systemctl is-active jenkins`
- Did the tunnel print `Waiting for connections...`? If it exited immediately, re-read its error.

### "Port 8080 already in use" on your own machine

Something else on your laptop owns 8080. Forward to a different local port:

```bash
aws ssm start-session \
  --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8081"]}'
```

Then browse to `http://localhost:8081` instead.

### Jenkins is very slow, or the service keeps restarting

Almost always memory. On the instance:

```bash
free -m
sudo journalctl -u jenkins -n 50 --no-pager
```

If you see the kernel killing Java, or under ~500 MB free, the instance is too small. Stop it, **Actions → Instance settings → Change instance type**, then start it again. (Changing type requires the instance to be stopped.)

Pick `t3.medium` / `t3.large` on a paid account, or `c7i-flex.large` / `m7i-flex.large` if your account is on the new Free Tier plan — a Free Tier account will refuse the `t3` types.

### `curl` returns 403 — is that broken?

No. `403` means Jenkins is running and requiring authentication. It is a healthy response from `/login`.

### Plugin installation hangs or fails

The instance cannot reach `updates.jenkins.io`. Test from the instance:

```bash
curl -I https://updates.jenkins.io/update-center.json
```

If that fails, the problem is outbound internet: check the route table has a `0.0.0.0/0` route to an internet gateway, and that the security group's outbound rule allows all traffic.

### Disk full

```bash
df -h /var/lib/jenkins
```

If it is near 100%, delete old build data in the Jenkins UI, or grow the EBS volume from the console (**Volumes → Modify volume**, then `sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1`).

---

## Part 7 — Cleanup (do not skip)

An instance you forget about bills you every hour.

### Option 1 — Stop it (keeps your work, pauses most charges)

**EC2 → Instances → select → Instance state → Stop instance**

You still pay for the 30 GB EBS volume (~$2.40/month), but not for compute. Your Jenkins config and jobs survive. Start it again any time.

> The **public IP changes** every time you stop and start. If you used Option B in Part 4, you will need the new IP.

### Option 2 — Terminate it (deletes everything, stops all charges)

**EC2 → Instances → select → Instance state → Terminate instance**

This deletes the instance and its volume. Your Jenkins setup is gone for good. This is what you want when the lab is over.

### Also clean up

- [ ] The inbound 8080 rule, if you added one in Part 4 Option B
- [ ] The security group `jenkins-lab-sg` (delete after the instance is terminated)
- [ ] The IAM role `jenkins-lab-ssm-role`, if you have no further use for it
- [ ] Check **EC2 → Elastic IPs** — an unattached Elastic IP bills you. You should not have one from this guide, but it is worth a look.

### Confirm nothing is left running

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key=='Name']|[0].Value]" \
  --output table
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Get a shell (console) | EC2 → instance → **Connect** → Session Manager tab |
| Get a shell (CLI) | `aws ssm start-session --target <ID>` |
| Install Jenkins | `sudo bash install-jenkins.sh` |
| Check status | `sudo systemctl status jenkins --no-pager` |
| Verify everything | `sudo bash verify-jenkins.sh` (copy it over first) |
| Watch startup live | `sudo journalctl -u jenkins -f` |
| Unlock password | `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` |
| Install log | `sudo tail -50 /var/log/jenkins-bootstrap.log` |
| User-data log | `sudo tail -80 /var/log/cloud-init-output.log` |
| Restart Jenkins | `sudo systemctl restart jenkins` |
| Start tunnel | `aws ssm start-session --target <ID> --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'` |
| Jenkins home | `/var/lib/jenkins` |
| Free memory | `free -m` |
| Free disk | `df -h /var/lib/jenkins` |

### Files in this guide

| File | Purpose |
|------|---------|
| [`scripts/install-jenkins.sh`](./scripts/install-jenkins.sh) | Installs Java 21 + Jenkins LTS. Use as user data or run by hand. |
| [`scripts/verify-jenkins.sh`](./scripts/verify-jenkins.sh) | Pass/fail health check with a fix hint for each failure. |

---

## What You Learned

- An EC2 instance is a rented computer; an AMI is its OS; EBS is its disk.
- A security group is a firewall, and the safest inbound rule is **none**.
- An IAM role lets a machine prove its identity with no stored keys to leak.
- User data runs once at first boot — and when it fails, `/var/log/cloud-init-output.log` tells you why.
- A missing `jenkins.service` means a missing *package*, not a broken service.
- HTTP `403` from `/login` is a healthy Jenkins.
- SSM port forwarding brings a private cloud service to `localhost` with none of the exposure of an open port.

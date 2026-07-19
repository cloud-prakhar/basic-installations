#!/usr/bin/env bash
#
# Jenkins LTS installer for Ubuntu 22.04 / 24.04 on AWS EC2.
#
# Two ways to use it:
#   1. Paste this whole file into EC2 "Advanced details -> User data" at launch.
#      It will run automatically on first boot, as root.
#   2. Run it by hand once you have a shell on the instance:
#        sudo bash install-jenkins.sh
#
# Safe to run more than once. If a run fails halfway, just run it again.
#
# All output is written to /var/log/jenkins-bootstrap.log, so you can see what
# happened even if you were not watching.
#
# NOTE ON WHY THIS IS NOT JUST "apt-get install jenkins":
# On a freshly booted Ubuntu instance, Ubuntu's own background updater
# (unattended-upgrades) holds the apt/dpkg lock for the first minute or two.
# A plain apt-get command fails with "Could not get lock", the script stops,
# and you end up on a server where Jenkins was never installed -- which shows
# up later as the confusing error "Unit jenkins.service could not be found".
# The waiting and retry logic below exists to prevent exactly that.

set -euo pipefail

# ---------------------------------------------------------------- checks ----
# These run BEFORE the logging redirect below, because writing the log file
# itself needs root -- checking first gives a clear error instead of a
# confusing "tee: Permission denied".
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this script must run as root."
  echo "       Try:  sudo bash $0"
  exit 1
fi

# Send everything (stdout and stderr) to the log file AND to the screen.
exec > >(tee -a /var/log/jenkins-bootstrap.log) 2>&1

echo "================================================================"
echo " Jenkins installation started: $(date -Is)"
echo "================================================================"

if ! grep -qi ubuntu /etc/os-release; then
  echo "ERROR: this script targets Ubuntu. Detected:"
  cat /etc/os-release | head -2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Keep a copy on the instance so it can be re-run easily after a failed boot.
mkdir -p /opt/jenkins-install
if [ -f "$0" ]; then
  install -m 0755 "$0" /opt/jenkins-install/install-jenkins.sh
fi

# ------------------------------------------------- wait out the apt lock ----
echo ""
echo ">>> Making sure no background updater is holding the package lock..."

# Stop Ubuntu's background updaters so they cannot grab the lock mid-install.
systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Then wait (at most 5 minutes) for any in-flight apt run to let go.
#
# IMPORTANT: do NOT use "cloud-init status --wait" here. When this script runs
# as EC2 user data it IS a child of cloud-init, so waiting for cloud-init to
# finish waits on a process that is itself waiting for this script -- a
# deadlock that hangs the boot forever with nothing installed.
if command -v fuser >/dev/null 2>&1; then
  for _ in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 &&
       ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      break
    fi
    echo "    package lock is busy; waiting..."
    sleep 5
  done
fi

# Make every apt command wait up to 10 minutes for the lock instead of failing.
APT_OPTS=(-y -o DPkg::Lock::Timeout=600)

# Retry a command up to 5 times with increasing delay. Used for anything that
# touches the network, since a brand-new instance may not have DNS ready yet.
retry() {
  local attempt=1
  until "$@"; do
    if [ "${attempt}" -ge 5 ]; then
      echo "ERROR: gave up after ${attempt} attempts: $*"
      return 1
    fi
    echo "    attempt ${attempt} failed; retrying in $((attempt * 10))s..."
    sleep "$((attempt * 10))"
    attempt=$((attempt + 1))
  done
}

# ------------------------------------------------------ clear stale state ---
# A previous failed run can leave behind a Jenkins apt entry pointing at a key
# that is missing or expired. That broken entry makes EVERY later "apt-get
# update" fail -- including the one in Step 1, before we ever get to the code
# in Step 2 that fixes the key. The script would then look like it is failing
# for the wrong reason, and re-running would never help.
#
# So: always start the Jenkins repo from a clean slate.
rm -f /etc/apt/sources.list.d/jenkins.list /usr/share/keyrings/jenkins-keyring.asc

# ------------------------------------------------------------ install java --
echo ""
echo ">>> Step 1/4: Installing Java 21 (Jenkins needs Java to run)..."
retry apt-get update "${APT_OPTS[@]}"
retry apt-get install "${APT_OPTS[@]}" \
  ca-certificates curl gnupg fontconfig openjdk-21-jre-headless
java -version

# ------------------------------------------------------- jenkins apt repo ---
echo ""
echo ">>> Step 2/4: Adding the official Jenkins package repository..."

# Jenkins rotates its package-signing key every few years, and the old key
# EXPIRES. Many guides still hardcode "jenkins.io-2023.key", which expired on
# 2026-03-26 -- using it makes apt fail with:
#   NO_PUBKEY ... / The repository ... is not signed.
#
# So rather than hardcode one name, try this year's key, then next year's,
# then the last one known to work. Pick the first that downloads AND is not
# expired. This keeps working across future rotations.
KEY_DEST=/usr/share/keyrings/jenkins-keyring.asc
YEAR=$(date +%Y)
KEY_FOUND=""

for KEY_NAME in "jenkins.io-${YEAR}.key" "jenkins.io-$((YEAR + 1)).key" "jenkins.io-2026.key"; do
  KEY_URL="https://pkg.jenkins.io/debian-stable/${KEY_NAME}"
  if ! curl -fsSL --retry 3 --retry-delay 5 "${KEY_URL}" -o "${KEY_DEST}" 2>/dev/null; then
    continue
  fi
  # Column 2 of gpg's colon output is validity; "e" means expired.
  VALIDITY=$(gpg --show-keys --with-colons "${KEY_DEST}" 2>/dev/null | awk -F: '/^pub/{print $2; exit}')
  if [ -n "${VALIDITY}" ] && [ "${VALIDITY}" != "e" ]; then
    echo "    using signing key: ${KEY_NAME}"
    KEY_FOUND="${KEY_NAME}"
    break
  fi
  echo "    ${KEY_NAME} is expired or unreadable; trying the next one..."
done

if [ -z "${KEY_FOUND}" ]; then
  rm -f "${KEY_DEST}"
  echo ""
  echo "ERROR: could not find a valid Jenkins signing key."
  echo "       Jenkins may have rotated it again. Check the current key name at:"
  echo "       https://www.jenkins.io/doc/book/installing/linux/"
  exit 1
fi

echo "deb [signed-by=${KEY_DEST}] https://pkg.jenkins.io/debian-stable binary/" \
  >/etc/apt/sources.list.d/jenkins.list

# ---------------------------------------------------------- install jenkins --
echo ""
echo ">>> Step 3/4: Installing Jenkins LTS..."
retry apt-get update "${APT_OPTS[@]}"
retry apt-get install "${APT_OPTS[@]}" jenkins

systemctl enable --now jenkins

# ------------------------------------------------------------- wait for up ---
echo ""
echo ">>> Step 4/4: Waiting for Jenkins to finish starting (up to 5 min)..."
if ! timeout 300 bash -c 'until curl -fsS -o /dev/null http://127.0.0.1:8080/login; do sleep 5; done'; then
  echo ""
  echo "ERROR: Jenkins did not come up within 5 minutes."
  echo "Recent service logs:"
  journalctl -u jenkins -n 40 --no-pager || true
  echo ""
  echo "Most common cause: not enough memory. Check with 'free -m'."
  echo "Jenkins needs at least 4 GB RAM (t3.medium or larger)."
  exit 1
fi

systemctl is-active --quiet jenkins

# ------------------------------------------------------------------ done ----
PASSWORD_FILE=/var/lib/jenkins/secrets/initialAdminPassword

echo ""
echo "================================================================"
echo " Jenkins is installed and running."
echo "================================================================"
echo ""
echo " Version : $(dpkg-query -W -f='${Version}' jenkins 2>/dev/null || echo unknown)"
echo " Service : $(systemctl is-active jenkins)"
echo " Port    : 8080 (on this instance, not yet reachable from your laptop)"
echo ""
if [ -f "${PASSWORD_FILE}" ]; then
  echo " Unlock password (you need this in the browser):"
  echo ""
  echo "     $(cat "${PASSWORD_FILE}")"
  echo ""
  echo " You can read it again any time with:"
  echo "     sudo cat ${PASSWORD_FILE}"
else
  echo " WARNING: ${PASSWORD_FILE} not found."
  echo " That file disappears after the setup wizard is completed once."
fi
echo ""
echo " Next: open a tunnel from your laptop, then browse to localhost:8080."
echo " See Part 4 of the deployment guide."
echo ""
echo " Full log of this run: /var/log/jenkins-bootstrap.log"
echo "================================================================"

touch /var/log/jenkins-bootstrap.done

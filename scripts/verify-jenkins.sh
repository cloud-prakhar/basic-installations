#!/usr/bin/env bash
#
# Health check for a Jenkins install. Run it ON THE EC2 INSTANCE:
#     sudo bash verify-jenkins.sh
#
# Prints a pass/fail line for each thing that has to be true before Jenkins
# will work in your browser. Tells you what to do about each failure.

PORT="${1:-8080}"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
hint() { echo "         -> $*"; }

echo ""
echo "Jenkins verification (port ${PORT})"
echo "----------------------------------------"

# 1. Is the package even installed?
if dpkg -l jenkins >/dev/null 2>&1; then
  ok "Jenkins package is installed ($(dpkg-query -W -f='${Version}' jenkins))"
else
  bad "Jenkins package is NOT installed"
  hint "The install script never finished. Check /var/log/cloud-init-output.log"
  hint "then re-run: sudo bash /opt/jenkins-install/install-jenkins.sh"

  # The most common reason installs fail now: the apt signing key expired.
  KEYRING=/usr/share/keyrings/jenkins-keyring.asc
  if [ -f "${KEYRING}" ]; then
    VALIDITY=$(gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null | awk -F: '/^pub/{print $2; exit}')
    if [ "${VALIDITY}" = "e" ]; then
      echo ""
      bad "The Jenkins signing key in ${KEYRING} has EXPIRED"
      hint "This is why apt could not install Jenkins (NO_PUBKEY / 'not signed')."
      hint "The widely-copied jenkins.io-2023.key expired on 2026-03-26."
      hint "Fix: sudo rm -f /etc/apt/sources.list.d/jenkins.list ${KEYRING}"
      hint "then re-run the installer, which picks the current key automatically."
    fi
  fi

  echo ""
  echo "Result: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# 1b. Warn if the signing key will expire soon, even on a working install.
KEYRING=/usr/share/keyrings/jenkins-keyring.asc
if [ -f "${KEYRING}" ] && command -v gpg >/dev/null 2>&1; then
  read -r KEY_VALIDITY KEY_EXPIRY <<<"$(gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null | awk -F: '/^pub/{print $2, $7; exit}')"
  if [ "${KEY_VALIDITY}" = "e" ]; then
    bad "Jenkins signing key has expired - future 'apt update' runs will fail"
    hint "sudo rm -f /etc/apt/sources.list.d/jenkins.list ${KEYRING} && re-run the installer"
  elif [ -n "${KEY_EXPIRY}" ] && [ "${KEY_EXPIRY}" -gt 0 ] 2>/dev/null; then
    DAYS_LEFT=$(( (KEY_EXPIRY - $(date +%s)) / 86400 ))
    if [ "${DAYS_LEFT}" -lt 90 ]; then
      echo "  [WARN] Jenkins signing key expires in ${DAYS_LEFT} days"
      echo "         -> re-run the installer before then to pick up the new key"
    else
      ok "Jenkins signing key is valid (${DAYS_LEFT} days remaining)"
    fi
  fi
fi

# 2. Java present?
if command -v java >/dev/null 2>&1; then
  ok "Java is installed ($(java -version 2>&1 | head -1))"
else
  bad "Java is not installed"
  hint "Run: sudo apt-get install -y openjdk-21-jre-headless"
fi

# 3. Service running?
STATE="$(systemctl is-active jenkins 2>/dev/null || true)"
if [ "${STATE}" = "active" ]; then
  ok "jenkins.service is active (running)"
else
  bad "jenkins.service is '${STATE:-not found}'"
  hint "See why with: sudo journalctl -u jenkins -n 50 --no-pager"
  hint "If it keeps restarting, check memory with: free -m (needs 4 GB)"
fi

# 4. Enabled at boot?
if systemctl is-enabled --quiet jenkins 2>/dev/null; then
  ok "jenkins.service is enabled (will start after a reboot)"
else
  bad "jenkins.service is not enabled at boot"
  hint "Run: sudo systemctl enable jenkins"
fi

# 5. Listening on the port?
if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/login" 2>/dev/null; then
  ok "Jenkins answers on http://127.0.0.1:${PORT}/login"
else
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" 2>/dev/null)"
  if [ "${CODE}" = "403" ]; then
    ok "Jenkins answers on port ${PORT} (HTTP 403 - this is normal and healthy)"
  else
    bad "Nothing answering on port ${PORT} (got '${CODE:-no response}')"
    hint "Jenkins can take 30-90 seconds to start after the service does."
    hint "Watch it with: sudo journalctl -u jenkins -f"
  fi
fi

# 6. Unlock password available?
SECRET=/var/lib/jenkins/secrets/initialAdminPassword
if [ -f "${SECRET}" ]; then
  ok "Unlock password file exists"
  if [ "$(id -u)" -eq 0 ]; then
    echo "         password: $(cat "${SECRET}")"
  else
    hint "Read it with: sudo cat ${SECRET}"
  fi
else
  echo "  [INFO] No unlock password file."
  echo "         -> Normal if you already completed the setup wizard."
fi

echo "----------------------------------------"
echo "Result: ${PASS} passed, ${FAIL} failed"
echo ""

if [ "${FAIL}" -eq 0 ]; then
  echo "Jenkins is healthy on the instance."
  echo "If your browser still cannot reach it, the problem is the tunnel or"
  echo "the security group, not Jenkins. See Part 4 of the guide."
fi

[ "${FAIL}" -eq 0 ]

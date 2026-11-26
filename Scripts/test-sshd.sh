#!/bin/bash
# Starts a throwaway sshd on 127.0.0.1:2222 (as the current user, no root
# needed) and prints the environment the live tests expect. Usage:
#
#   Scripts/test-sshd.sh start   # starts sshd, writes .build/test-sshd/env.sh
#   source .build/test-sshd/env.sh && swift test --filter Live
#   Scripts/test-sshd.sh stop
#
# A second sshd on the next port (REACHLY_TEST_SSH_NOSFTP_PORT to choose
# another) has no SFTP subsystem, for the test that SFTP fails promptly there.
# Both listen on 127.0.0.1 only; stop ends only the processes start began.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/test-sshd"
PORT="${REACHLY_TEST_SSH_PORT:-2222}"
NOSFTP_PORT="${REACHLY_TEST_SSH_NOSFTP_PORT:-$((PORT + 1))}"

# write_config FILE PORT PIDFILE WITH_SFTP
write_config() {
  local file="$1" port="$2" pidfile="$3" with_sftp="$4"
  {
    cat <<CONF
Port $port
ListenAddress 127.0.0.1
HostKey "$DIR/host_ed25519"
AuthorizedKeysFile "$DIR/authorized_keys"
PidFile "$pidfile"
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel VERBOSE
CONF
    if [ "$with_sftp" = yes ]; then
      echo "# The SFTP live tests need the subsystem; without it every SFTP request is refused."
      echo "Subsystem sftp internal-sftp"
    fi
    cat <<CONF
# The live tests connect concurrently and some of them abort on purpose
# (declined host keys): never drop pending connections at random, and do not
# penalise 127.0.0.1 for the aborted ones (OpenSSH 9.8+ does by default).
MaxStartups 100
PerSourcePenalties no
CONF
  } > "$file"
  # Older sshd has no PerSourcePenalties and refuses the whole file: drop the line then.
  local check
  check="$(/usr/sbin/sshd -t -f "$file" 2>&1 || true)"
  if grep -qi "PerSourcePenalties" <<< "$check"; then
    sed -i '' '/^PerSourcePenalties/d' "$file"
    echo "sshd here predates PerSourcePenalties; line dropped from $(basename "$file")"
  fi
}

case "${1:-}" in
  start)
    mkdir -p "$DIR"
    [ -f "$DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "reachly-test-host" -f "$DIR/host_ed25519"
    [ -f "$DIR/user_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "reachly-test-user" -f "$DIR/user_ed25519"
    cp "$DIR/user_ed25519.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/authorized_keys"
    write_config "$DIR/sshd_config" "$PORT" "$DIR/sshd.pid" yes
    write_config "$DIR/sshd_nosftp_config" "$NOSFTP_PORT" "$DIR/sshd_nosftp.pid" no
    if ! /usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"; then
      echo "sshd failed to start; see $DIR/sshd.log" >&2
      tail -5 "$DIR/sshd.log" >&2
      exit 1
    fi
    if ! /usr/sbin/sshd -f "$DIR/sshd_nosftp_config" -E "$DIR/sshd_nosftp.log"; then
      echo "the sshd without SFTP failed to start on port $NOSFTP_PORT; see $DIR/sshd_nosftp.log" >&2
      tail -5 "$DIR/sshd_nosftp.log" >&2
      sleep 0.3
      [ -f "$DIR/sshd.pid" ] && kill "$(cat "$DIR/sshd.pid")" && rm -f "$DIR/sshd.pid"
      exit 1
    fi
    # Wait until both accept a login, not just a connection: on a busy CI runner the first sessions can
    # otherwise fail while sshd is still starting up.
    for port in "$PORT" "$NOSFTP_PORT"; do
      ready=no
      for _ in $(seq 50); do
        if ssh -q -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 \
             -i "$DIR/user_ed25519" -p "$port" 127.0.0.1 true 2>/dev/null; then ready=yes; break; fi
        sleep 0.2
      done
      [ "$ready" = yes ] || { echo "sshd on port $port does not accept a login yet; see $DIR" >&2; tail -20 "$DIR/sshd.log" >&2; }
    done
    printf 'export REACHLY_TEST_SSH_PORT=%s\nexport REACHLY_TEST_SSH_NOSFTP_PORT=%s\nexport REACHLY_TEST_SSH_KEY=%q\n' "$PORT" "$NOSFTP_PORT" "$DIR/user_ed25519" > "$DIR/env.sh"
    echo "sshd listening on 127.0.0.1:$PORT (pid $(cat "$DIR/sshd.pid")), without SFTP on 127.0.0.1:$NOSFTP_PORT (pid $(cat "$DIR/sshd_nosftp.pid"))"
    echo "source $DIR/env.sh && swift test --filter Live"
    ;;
  stop)
    stopped=no
    for pidfile in "$DIR/sshd.pid" "$DIR/sshd_nosftp.pid"; do
      if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" && rm -f "$pidfile" && stopped=yes; fi
    done
    if [ "$stopped" = yes ]; then echo "stopped"; else echo "not running"; fi
    ;;
  *)
    echo "usage: $0 start|stop" >&2; exit 2 ;;
esac

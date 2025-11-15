#!/bin/bash
set -u  # don't exit on non-zero so we can report errors, but still catch unset vars

# Enable UFW non-interactively
sudo ufw --force enable

# list of ports/ranges you requested
ports=(80 443 2022 5657 56423 8080 25565:25599 19132:19199)

# function to add a rule and report failure without exiting
add_rule() {
  proto=$1
  port_token=$2
  # Use the full "proto/from/to/port" form which is robust for ranges
  if ! sudo ufw allow proto "${proto}" from any to any port "${port_token}"; then
    echo "⚠️  Failed to add ${proto} rule for ${port_token}" >&2
  else
    echo "Added ${proto} ${port_token}"
  fi
}

# Add both TCP and UDP for each requested port/range
for p in "${ports[@]}"; do
  add_rule tcp "${p}"
done

for p in "${ports[@]}"; do
  add_rule udp "${p}"
done

sudo ufw reload
echo "✅ UFW setup complete - attempted to allow both TCP & UDP for: ${ports[*]}"
echo "Check status with: sudo ufw status numbered"

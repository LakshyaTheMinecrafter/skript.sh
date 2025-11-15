#!/usr/bin/env bash
set -u

# Ports/ranges you requested (exactly these)
TOKENS=(80 443 2022 5657 56423 8080 25565:25599 19132:19199)

# Enable UFW without interactive prompt
sudo ufw --force enable

# helper: expand tokens to individual ports
expand_token_to_ports() {
  token="$1"
  if [[ "$token" =~ ^[0-9]+:[0-9]+$ ]]; then
    # colon range like 25565:25599
    start=${token%%:*}
    end=${token##*:}
    seq "$start" "$end"
  elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
    # dash range (just in case)
    start=${token%%-*}
    end=${token##*-}
    seq "$start" "$end"
  else
    # single port
    echo "$token"
  fi
}

# Add rules for a given proto
add_proto_rules() {
  proto="$1"  # tcp or udp
  for token in "${TOKENS[@]}"; do
    # expand token to one or more ports
    while IFS= read -r port; do
      # Use the simple form "ufw allow PORT/PROTO" which is reliable for single ports
      if sudo ufw allow "${port}/${proto}" >/dev/null 2>&1; then
        printf "Added %s/%s\n" "$port" "$proto"
      else
        # Print a warning but continue
        printf "Warning: could not add %s/%s (may already exist or be invalid)\n" "$port" "$proto" >&2
      fi
    done < <(expand_token_to_ports "$token")
  done
}

# Add TCP then UDP
add_proto_rules tcp
add_proto_rules udp

# Reload and show summary
sudo ufw reload
echo "✅ UFW setup complete — attempted to allow the exact ports (TCP & UDP)."
echo "Check active rules: sudo ufw status numbered"

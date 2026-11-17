ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ':5911$'

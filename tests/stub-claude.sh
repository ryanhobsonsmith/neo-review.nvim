#!/usr/bin/env bash
# Stands in for the interactive claude TUI: logs its start and every line
# typed into its pty to the file named by $1.
log="$1"
printf 'SPAWN %s\n' "$$" >>"$log"
while IFS= read -r line; do
  printf 'RECV %s\n' "$line" >>"$log"
done

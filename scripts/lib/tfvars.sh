#!/usr/bin/env bash
# Shared helpers for reading/writing simple top-level keys in a Terraform .tfvars file.
#
# Deliberately portable: no `sed -i` (GNU-only semantics differ from BSD/macOS, where `-i`
# consumes the next argument as a backup suffix), and no in-place edit without verification.
#
# Only handles flat `key = value` assignments, which is all terraform.tfvars uses here.

# get_tfvar <file> <key>
# Prints the raw HCL value (quotes included) for <key>, or nothing if the key is absent
# or only present as a comment.
get_tfvar() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/#.*$/, "", line)
      if (match(line, "^[[:space:]]*" k "[[:space:]]*=")) {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

# set_tfvar <file> <key> <raw-hcl-value>
# Replaces the first uncommented `key = ...` assignment, or appends one if none exists.
# <raw-hcl-value> is written verbatim, so quote strings yourself: set_tfvar f k '"v"'
set_tfvar() {
  local file="$1" key="$2" value="$3"

  if [[ ! -f "$file" ]]; then
    echo "tfvars file not found: $file" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  KEY="$key" VALUE="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    {
      if (!done && $0 !~ /^[[:space:]]*#/ && match($0, "^[[:space:]]*" k "[[:space:]]*=")) {
        print k " = " v
        done = 1
        next
      }
      print
    }
    END { if (!done) print k " = " v }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"

  # Verify rather than trust: a silent no-op here would leave the stack in an unintended state.
  local got
  got="$(get_tfvar "$file" "$key")"
  if [[ "$got" != "$value" ]]; then
    echo "Failed to set '$key' in $file (wanted '$value', got '${got:-<missing>}')." >&2
    return 1
  fi
}

# confirm <prompt>
# Returns 0 if the user agrees. Honours ASSUME_YES=true for non-interactive use.
confirm() {
  local prompt="$1" reply
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Refusing to proceed without confirmation in a non-interactive shell (pass --yes)." >&2
    return 1
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# --- marker comments ---------------------------------------------------------------------------
# Bookkeeping that shutdown.sh needs to hand to resume.sh is stored as a comment, not as a real
# assignment: Terraform warns about values for undeclared variables in an auto-loaded
# terraform.tfvars, and inventing a fake variable just to pass state between scripts is worse than
# a comment the operator can also read.

MARKER_PREFIX="# hibernate-state:"

# set_marker <file> <name> <raw-value>
set_marker() {
  local file="$1" name="$2" value="$3" tmp
  tmp="$(mktemp)"
  NAME="$name" VALUE="$value" PREFIX="$MARKER_PREFIX" awk '
    BEGIN { p = ENVIRON["PREFIX"]; n = ENVIRON["NAME"]; v = ENVIRON["VALUE"]; done = 0 }
    {
      if (!done && index($0, p " " n " =") == 1) { print p " " n " = " v; done = 1; next }
      print
    }
    END { if (!done) print p " " n " = " v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# get_marker <file> <name>
get_marker() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  NAME="$name" PREFIX="$MARKER_PREFIX" awk '
    BEGIN { p = ENVIRON["PREFIX"]; n = ENVIRON["NAME"] }
    index($0, p " " n " =") == 1 {
      sub("^" p " " n " =[[:space:]]*", "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file"
}

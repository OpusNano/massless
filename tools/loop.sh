#!/usr/bin/env bash
# Runs unattended Claude sessions, one docs/PLAN.md step each.
# usage: tools/loop.sh [steps]   (default 12, hard cap 12)
set -u

MAX=12
steps=${1:-$MAX}
if ! [[ $steps =~ ^[0-9]+$ ]] || ((steps < 1)); then
	echo "usage: $0 [steps 1-$MAX]" >&2
	exit 2
fi
((steps > MAX)) && steps=$MAX

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
mkdir -p .loop
exec 9>.loop/lock
flock -n 9 || { echo "another loop is already running" >&2; exit 1; }
[ "$(git branch --show-current)" = rust ] || { echo "not on branch rust" >&2; exit 1; }

ran=0
push_fails=0

finish() { # finish <exit code> <reason>
	echo "stop: $2"
	echo "ran $ran steps"
	exit "$1"
}
check_stop() { if [ -f STOP ]; then finish 0 "$(cat STOP)"; fi; }

# One line per event: assistant text, tool calls, final result.
feed() {
	jq -rR --unbuffered '
		def one: tostring | gsub("\\s+"; " ") | .[0:200];
		fromjson? // empty
		| if .type == "assistant" then
			.message.content[]?
			| if .type == "text" then "  > " + (.text | one)
			  elif .type == "tool_use" then "  $ " + .name + ": "
				+ ((.input.description // .input.command // .input.file_path // .input.pattern // "") | one)
			  else empty end
		  elif .type == "result" then
			"  = \(.subtype): \(.num_turns) turns, \((.duration_ms // 0) / 600 | round / 100) min\n  = " + ((.result // "") | one)
		  else empty end'
}

for ((n = 1; n <= steps; n++)); do
	check_stop
	before=$(git rev-parse HEAD)
	ts=$(date +%Y%m%d-%H%M%S)
	echo "== step $n/$steps ($ts)"

	claude -p "proceed. (Unattended: started by tools/loop.sh, step $n of $steps. Nobody can answer during this session.)" \
		--model claude-opus-5-5 --effort high --dangerously-skip-permissions \
		--output-format stream-json --verbose </dev/null |
		tee ".loop/$ts-step$n.jsonl" | feed
	ran=$n

	check_stop
	[ "$(git rev-parse HEAD)" = "$before" ] && finish 1 "step made no commit"
	if [ -f Cargo.toml ]; then
		cargo test --release >".loop/$ts-step$n-test.log" 2>&1 ||
			finish 1 "cargo test failed, see .loop/$ts-step$n-test.log"
		cargo clippy --release --all-targets -- -D warnings >".loop/$ts-step$n-clippy.log" 2>&1 ||
			finish 1 "clippy failed, see .loop/$ts-step$n-clippy.log"
	fi
	if git push -q origin rust; then
		push_fails=0
	else
		push_fails=$((push_fails + 1))
		echo "push failed ($push_fails in a row)"
		((push_fails >= 2)) && finish 1 "push failed twice in a row"
	fi
	git log --reverse --format='  * %s' "$before..HEAD"
done
echo "ran $ran steps"

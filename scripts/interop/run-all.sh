#!/bin/zsh
# Runs the official OpenTelemetry SDKs (Go, Node, .NET, Python) against a
# fresh magnife-ingest helper and checks with sqlite3 that every trace, span,
# log and metric export landed. Prints PASS/FAIL per SDK and protocol.
#
#   scripts/interop/run-all.sh [base-port]    # gRPC on base-port, HTTP on base-port+1 (default 34317)
#
# Each app is configured only by standard environment variables, pointing at
# localhost (as users do), and exits non-zero on any exporter error.
# SDKs whose toolchain is missing are skipped. First runs install packages
# (go modules, npm, NuGet, PyPI); later runs work offline.
set -uo pipefail

here="${0:A:h}"
ingest="$here/../../ingest"
base=${1:-34317}
grpc_port=$base
http_port=$((base + 1))

work=$(mktemp -d /tmp/magnife-interop.XXXXXX)
db="$work/magnife.sqlite"
trap 'kill $helper_pid 2>/dev/null; wait $helper_pid 2>/dev/null; rm -rf "$work"' EXIT

say() { print -r -- "$*" >&2 }

# --- helper ------------------------------------------------------------------
say "building magnife-ingest"
CGO_ENABLED=0 go -C "$ingest" build -o "$work/magnife-ingest" ./cmd/magnife-ingest || exit 1
"$work/magnife-ingest" --no-stdin -v --db "$db" \
	--grpc 127.0.0.1:$grpc_port --http 127.0.0.1:$http_port >"$work/helper.out" 2>"$work/helper.err" &
helper_pid=$!
for _ in {1..50}; do
	grep -q '"type":"ports"' "$work/helper.out" 2>/dev/null && break
	sleep 0.1
done
ports=$(grep -m1 '"type":"ports"' "$work/helper.out")
if [[ $ports != *'"grpc":{"addr":"127.0.0.1:'$grpc_port'","state":"listening"}'* ||
	$ports != *'"http":{"addr":"127.0.0.1:'$http_port'","state":"listening"}'* ]]; then
	say "helper is not listening on both ports: ${ports:-no ports line}"
	cat "$work/helper.err" >&2
	exit 1
fi
say "helper listening: gRPC $grpc_port, HTTP $http_port, database $db"

# --- SDK apps ------------------------------------------------------------------
prepare_go() {
	command -v go >/dev/null || return 1
	go -C "$here/go" build -o "$work/interop-go" . >&2
}
run_go() { "$work/interop-go" }

prepare_node() {
	command -v node >/dev/null || return 1
	[[ -d $here/node/node_modules ]] || npm --prefix "$here/node" install --no-audit --no-fund >&2
}
run_node() { node "$here/node/index.mjs" }

prepare_dotnet() {
	command -v dotnet >/dev/null || return 1
	DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
		dotnet build "$here/dotnet/Interop.csproj" -c Release -o "$work/dotnet" -v quiet -nologo >"$work/dotnet-build.log" ||
		{ cat "$work/dotnet-build.log" >&2; return 1 }
}
run_dotnet() { DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet "$work/dotnet/Interop.dll" }

prepare_python() {
	command -v python3 >/dev/null || return 1
	local venv="$here/python/.venv"
	if [[ ! -x $venv/bin/opentelemetry-instrument ]]; then
		python3 -m venv "$venv" && "$venv/bin/pip" install -q -r "$here/python/requirements.txt" >&2 || return 1
	fi
}
# opentelemetry-instrument configures the SDK from the environment; the
# logging switch makes Python's logging module export logs.
run_python() {
	OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true \
		"$here/python/.venv/bin/opentelemetry-instrument" "$here/python/.venv/bin/python" "$here/python/app.py"
}

# "default" leaves OTEL_EXPORTER_OTLP_PROTOCOL unset, as a user who copies
# only the endpoint would; default_protocol is what each SDK then uses.
typeset -A protocols=(
	go "grpc http/protobuf default"
	node "grpc http/protobuf http/json default"
	dotnet "grpc http/protobuf default"
	python "grpc http/protobuf default"
)
typeset -A default_protocol=(
	go http/protobuf # the app's own choice; the Go exporters are picked in code
	node http/protobuf
	dotnet grpc
	python grpc # opentelemetry-distro's default
)

q() { sqlite3 -readonly "$db" "$1" 2>/dev/null }

# check <service> <ids json> prints "traces logs metrics" verdicts.
check() {
	local svc=$1 ids=$2 tid root dbs call
	read tid root dbs call < <(print -r -- "$ids" | python3 -c \
		'import json,sys; d=json.load(sys.stdin); print(d["trace_id"], d["root_span_id"], d["db_span_id"], d["call_span_id"])')
	# Batches commit within 50 ms of the response; allow for a slow machine.
	for _ in {1..30}; do
		[[ $(q "SELECT span_count FROM traces WHERE trace_id = '$tid'") == 3 ]] && break
		sleep 0.1
	done
	local traces=FAIL logs=FAIL metrics=FAIL
	local trace_row=$(q "SELECT root_span_id, root_service, route, span_count, error_count, status FROM traces WHERE trace_id = '$tid'")
	local spans_ok=$(q "SELECT COUNT(*) FROM spans WHERE trace_id = '$tid' AND service_name = '$svc' AND (
		(span_id = '$root' AND parent_span_id IS NULL AND kind = 2 AND http_method = 'GET' AND http_route = '/orders/{id}') OR
		(span_id = '$dbs' AND parent_span_id = '$root' AND db_system = 'postgresql' AND db_statement LIKE 'SELECT%') OR
		(span_id = '$call' AND parent_span_id = '$root' AND status_code = 2 AND http_status_code = 500
			AND events LIKE '%\"name\":\"exception\"%'))")
	[[ $trace_row == "$root|$svc|GET /orders/{id}|3|1|2" && $spans_ok == 3 ]] && traces=PASS
	[[ $traces == FAIL ]] && say "  traces row: '$trace_row', matching spans: $spans_ok/3"

	local linked=$(q "SELECT COUNT(*) FROM logs WHERE service_name = '$svc' AND trace_id = '$tid' AND span_id = '$dbs' AND severity_number = 9")
	local loose=$(q "SELECT COUNT(*) FROM logs WHERE service_name = '$svc' AND trace_id IS NULL AND body = 'interop run finished' AND severity_number = 13")
	[[ $linked == 1 && $loose == 1 ]] && logs=PASS
	[[ $logs == FAIL ]] && say "  logs: linked to the db span $linked/1, without a trace $loose/1"

	grep -q "msg=\"dropped metrics\" service=$svc " "$work/helper.err" && metrics=PASS
	print -r -- "$traces $logs $metrics"
}

failed=0
printf '%-8s %-16s %-7s %-7s %-7s %s\n' SDK PROTOCOL TRACES LOGS METRICS EXPORTS
for sdk in go node dotnet python; do
	if ! prepare_$sdk; then
		printf '%-8s %-16s %s\n' $sdk - "SKIP (toolchain or packages unavailable)"
		continue
	fi
	for proto in ${=protocols[$sdk]}; do
		effective=$proto
		[[ $proto == default ]] && effective=${default_protocol[$sdk]}
		port=$http_port
		[[ $effective == grpc ]] && port=$grpc_port
		svc="interop-$sdk-${proto//\//-}"
		env=(OTEL_SERVICE_NAME=$svc OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:$port)
		[[ $proto != default ]] && env+=(OTEL_EXPORTER_OTLP_PROTOCOL=$proto)
		# A subshell with none of the caller's OTEL_* variables, only these.
		out=$(
			unset -m 'OTEL_*'
			export "${env[@]}"
			run_$sdk 2>"$work/$svc.err"
		)
		code=$?
		exports=PASS
		if (( code != 0 )); then
			exports="FAIL (exit $code)"
			sed 's/^/  /' "$work/$svc.err" | cut -c1-300 | head -20 >&2
		fi
		ids=$(print -r -- "$out" | grep -m1 '"trace_id"')
		if [[ -z $ids ]]; then
			verdict="FAIL FAIL FAIL"
		else
			verdict=$(check $svc "$ids")
		fi
		label=$proto
		[[ $proto == default ]] && label="($effective)"
		printf '%-8s %-16s %-7s %-7s %-7s %s\n' $sdk $label ${=verdict} "$exports"
		[[ $verdict == "PASS PASS PASS" && $exports == PASS ]] || failed=1
	done
done

# The helper's stdout must hold protocol lines only.
if grep -v '^{"type":"' "$work/helper.out" >&2; then
	say "FAIL: non-protocol lines on the helper's stdout"
	failed=1
fi
exit $failed

import Foundation

/// A stand-in for magnife-ingest, for unit tests and the self-test only.
/// It prints protocol lines (one split across two writes, one malformed,
/// one of an unknown type), answers stdin commands, and exits on stdin EOF.
///   FAKE_HELPER_IGNORE_EOF=1   keeps running after EOF, until terminated
public enum FakeHelper {
    public static let script = #"""
    #!/bin/zsh
    print -r -- "{\"type\":\"error\",\"message\":\"args: $*\"}"
    ports='{"type":"ports","grpc":{"addr":"127.0.0.1:4317","state":"listening"},"http":{"addr":"127.0.0.1:4318","state":"busy","owner":"otelcol-contrib","pid":4242}}'
    print -r -- $ports
    print -rn -- '{"type":"batch","seq":1,"spans":3,'
    sleep 0.05
    print -r -- '"logs":1,"traces":["t1"],"error_traces":[]}'
    print -r -- 'not json'
    print -r -- '{"type":"future","detail":1}'
    print -u2 -- "fake helper: started"
    seq=1
    while IFS= read -r line; do
      case $line in
        retry) print -r -- $ports ;;
        prune) print -r -- '{"type":"pruned","traces":1,"spans":2,"logs":3}' ;;
        retention\ *) print -r -- "{\"type\":\"error\",\"message\":\"$line\"}" ;;
      esac
    done
    if [[ -n ${FAKE_HELPER_IGNORE_EOF:-} ]]; then
      while true; do sleep 0.1; done
    fi
    exit 0
    """#

    /// Writes the script as an executable file in `directory`.
    public static func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "fake-magnife-ingest")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

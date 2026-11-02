package helper

import (
	"strings"
	"testing"
	"time"
)

func TestReadCommandsSkipsOverlongLines(t *testing.T) {
	long := strings.Repeat("x", 100_000) // bufio.Scanner would stop at 64 KiB
	in := strings.NewReader("prune\n" + long + "\nretention 60\r\nretry")
	lines := make(chan string, 10)
	eof := make(chan struct{})
	go readCommands(in, lines, eof)

	var got []string
	for done := false; !done; {
		select {
		case l := <-lines:
			got = append(got, strings.Join(strings.Fields(l), " "))
		case <-eof:
			done = true
		case <-time.After(2 * time.Second):
			t.Fatal("readCommands did not reach EOF")
		}
	}
	// A line sent just before EOF may still be in the channel.
	for len(lines) > 0 {
		got = append(got, strings.Join(strings.Fields(<-lines), " "))
	}
	if want := "prune|retention 60|retry"; strings.Join(got, "|") != want {
		t.Fatalf("commands %q, want %q", got, want)
	}
}

func TestCheckLoopback(t *testing.T) {
	for addr, ok := range map[string]bool{
		"127.0.0.1:4317": true, "127.0.0.1:0": true, "[::1]:4318": true,
		"0.0.0.0:4317": false, "localhost:4317": false, ":4317": false, "192.168.1.2:4317": false, "4317": false,
	} {
		if err := checkLoopback("grpc", addr); (err == nil) != ok {
			t.Errorf("checkLoopback(%q) = %v, want ok=%v", addr, err, ok)
		}
	}
}

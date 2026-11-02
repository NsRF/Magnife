package ports

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"testing"
)

// TestMain lets the test binary act as "another process" holding a port:
// with MAGNIFE_TEST_HOLD=<network> <address> it listens, prints the port and
// waits for stdin to close.
func TestMain(m *testing.M) {
	if spec := os.Getenv("MAGNIFE_TEST_HOLD"); spec != "" {
		var network, addr string
		fmt.Sscan(spec, &network, &addr)
		ln, err := net.Listen(network, addr)
		if err != nil {
			fmt.Println("error", err)
			os.Exit(1)
		}
		fmt.Println(ln.Addr().(*net.TCPAddr).Port)
		io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// hold starts a child process listening on network/addr and returns its port.
func hold(t *testing.T, network, addr string) (port int, pid int) {
	t.Helper()
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(), "MAGNIFE_TEST_HOLD="+network+" "+addr)
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stdin.Close(); cmd.Wait() })
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	port, err = strconv.Atoi(line[:len(line)-1])
	if err != nil {
		t.Fatalf("holder: %q", line)
	}
	return port, cmd.Process.Pid
}

// TestBusyWildcardListener verifies the platform research item: with
// SO_REUSEADDR (which Go sets on every listener), binding 127.0.0.1:P
// succeeds while another process holds *:P. Check must still call it busy.
func TestBusyWildcardListener(t *testing.T) {
	for _, c := range []struct{ name, network, addr string }{
		{"IPv4 wildcard *:P", "tcp4", "0.0.0.0:0"},
		{"dual-stack wildcard [::]:P", "tcp", ":0"},
		{"loopback 127.0.0.1:P", "tcp4", "127.0.0.1:0"},
	} {
		t.Run(c.name, func(t *testing.T) {
			port, pid := hold(t, c.network, c.addr)
			target := fmt.Sprintf("127.0.0.1:%d", port)

			// Record what a plain bind does, the behavior the research flagged.
			if ln, err := net.Listen("tcp", target); err == nil {
				t.Logf("net.Listen(%q) SUCCEEDED while pid %d holds %s:%d", target, pid, c.addr[:len(c.addr)-2], port)
				ln.Close()
			} else {
				t.Logf("net.Listen(%q) failed: %v", target, err)
			}

			got := Check(context.Background(), target)
			if !got.Busy || got.PID != pid || got.Name == "" {
				t.Fatalf("Check(%s) = %+v, want busy with pid %d", target, got, pid)
			}
			t.Logf("Check: busy, owner %q pid %d", got.Name, got.PID)

			// Without lsof (another user's process), the connect probe still sees it.
			saved := LsofPath
			LsofPath = ""
			defer func() { LsofPath = saved }()
			if got := Check(context.Background(), target); !got.Busy || got.PID != 0 {
				t.Fatalf("probe-only Check = %+v, want busy without owner", got)
			}
		})
	}
}

func TestFreePortAndOwnListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	// lsof ignores this process; the probe connects to our own listener, so
	// Check is only meaningful before binding. After closing it, the port is free.
	if got := lsofListener(context.Background(), ln.Addr().(*net.TCPAddr).Port); got.Busy {
		t.Fatalf("own listener reported busy: %+v", got)
	}
	ln.Close()
	if got := Check(context.Background(), addr); got.Busy {
		t.Fatalf("free port reported busy: %+v", got)
	}
	if got := Check(context.Background(), "127.0.0.1:0"); got.Busy {
		t.Fatal("port 0 is never busy")
	}
}

func TestParseLsof(t *testing.T) {
	out := []byte("p100\ncmagnife-ingest\nf3\nn127.0.0.1:4317\np4242\ncotelcol-contrib\nf7\nn*:4317\n")
	if got := parseLsof(out, 100); got != (Owner{Busy: true, Name: "otelcol-contrib", PID: 4242}) {
		t.Fatalf("got %+v", got)
	}
	if got := parseLsof(out[:firstBlock(out)], 100); got.Busy {
		t.Fatalf("own pid only: %+v", got)
	}
	if got := parseLsof(nil, 1); got.Busy {
		t.Fatal("empty output")
	}
}

// firstBlock returns the length of the first process block.
func firstBlock(b []byte) int {
	for i := 1; i < len(b); i++ {
		if b[i] == 'p' && b[i-1] == '\n' {
			return i
		}
	}
	return len(b)
}

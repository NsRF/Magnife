// Package ports finds other processes listening on a TCP port before the
// helper binds it.
//
// A plain bind is not enough on macOS: Go listeners set SO_REUSEADDR, and with
// it binding 127.0.0.1:P succeeds while another process holds *:P (verified
// in TestBusyWildcardListener), which would silently split traffic.
package ports

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Owner says whether a port is held by another process, and which one when
// it can be found (lsof only sees the current user's processes).
type Owner struct {
	Busy bool
	Name string // process name, "" when unknown
	PID  int    // 0 when unknown
}

// LsofPath is the lsof binary; tests may clear it to exercise the probe alone.
var LsofPath = "/usr/sbin/lsof"

// Check looks for any other listener on addr's port, on any address. A port
// of 0 is never busy.
func Check(ctx context.Context, addr string) Owner {
	_, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return Owner{}
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port == 0 {
		return Owner{}
	}

	var (
		wg    sync.WaitGroup
		lsof  Owner
		probe bool
	)
	wg.Add(2)
	go func() { defer wg.Done(); lsof = lsofListener(ctx, port) }()
	go func() { defer wg.Done(); probe = connectProbe(ctx, port) }()
	wg.Wait()

	if lsof.Busy {
		if name := processName(ctx, lsof.PID); name != "" {
			lsof.Name = name
		}
		return lsof
	}
	// A listener owned by another user is invisible to lsof but still accepts
	// connections on loopback (directly or through a wildcard bind).
	return Owner{Busy: probe}
}

// lsofListener asks lsof for TCP listeners on port, ignoring this process.
func lsofListener(ctx context.Context, port int) Owner {
	if LsofPath == "" {
		return Owner{}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	// Exit status 1 means "nothing found"; any output is still parsed.
	out, _ := exec.CommandContext(ctx, LsofPath, "-nP", "-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN", "-Fpcn").Output()
	return parseLsof(out, os.Getpid())
}

// PsPath is the ps binary used for full process names.
var PsPath = "/bin/ps"

// processName returns the executable name of pid. lsof cuts command names at
// 15 characters (com.docker.backend shows as com.docker.back), ps -o comm
// prints the full executable path.
func processName(ctx context.Context, pid int) string {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, PsPath, "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	path := strings.TrimSpace(string(out))
	if err != nil || path == "" {
		return ""
	}
	return filepath.Base(path)
}

// parseLsof reads lsof -F output: "p<pid>" starts a process, "c<name>" names
// it, then "f"/"n" lines describe its files.
func parseLsof(out []byte, self int) Owner {
	var cur Owner
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			if cur.Busy {
				return cur
			}
			pid, _ := strconv.Atoi(line[1:])
			cur = Owner{Busy: pid != 0 && pid != self, PID: pid}
		case 'c':
			cur.Name = line[1:]
		}
	}
	if cur.Busy {
		return cur
	}
	return Owner{}
}

// connectProbe reports whether anything accepts connections on the loopback
// addresses for port.
func connectProbe(ctx context.Context, port int) bool {
	d := net.Dialer{Timeout: 300 * time.Millisecond}
	results := make(chan bool, 2)
	for _, host := range []string{"127.0.0.1", "::1"} {
		go func() {
			c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
			if err == nil {
				c.Close()
			}
			results <- err == nil
		}()
	}
	a, b := <-results, <-results
	return a || b
}

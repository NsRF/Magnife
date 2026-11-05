package store

import (
	"context"
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"time"
)

// ErrClosed is returned by Submit after Close.
var ErrClosed = errors.New("writer is closed")

// Events receives what the writer did; calls come from the writer goroutine.
type Events interface {
	Batch(BatchResult)
	Pruned(PruneResult)
	Error(error)
}

// Writer is the one goroutine that writes the database. Receivers hand it
// decoded batches; the bounded queue is the backpressure.
type Writer struct {
	// Tunables; set before Start.
	MaxRecords int           // commit when this many spans and logs are pending
	MaxDelay   time.Duration // commit this long after the first pending record
	PruneEvery time.Duration
	QueueLen   int

	store      *Store
	events     Events
	retentionS int64 // owned by the writer goroutine after Start

	in   chan *Batch
	ctl  chan func()
	done chan struct{}

	mu     sync.RWMutex
	closed bool

	stopBy  atomic.Int64 // Unix ns after which queued batches are dropped; 0 = never
	dropped int          // records dropped at stopBy; read after done closes
}

// NewWriter returns a writer with the contract's defaults: a batch every
// 50 ms or 2,000 records, pruning every 60 s (or every retention period
// when that is shorter; see PruneInterval).
func NewWriter(s *Store, retentionS int64, ev Events) *Writer {
	return &Writer{
		MaxRecords: 2000,
		MaxDelay:   50 * time.Millisecond,
		PruneEvery: 60 * time.Second,
		QueueLen:   256,
		store:      s,
		events:     ev,
		retentionS: retentionS,
		ctl:        make(chan func()),
		done:       make(chan struct{}),
	}
}

// Start runs the writer goroutine.
func (w *Writer) Start() {
	w.in = make(chan *Batch, w.QueueLen)
	go w.run()
}

// Submit queues a batch, blocking while the queue is full. A batch larger
// than MaxRecords is queued in chunks of at most MaxRecords, so one huge
// request never becomes one long transaction, and a helper told to stop
// drops the chunks still queued at its deadline instead of committing them all.
func (w *Writer) Submit(ctx context.Context, b *Batch) error {
	if b == nil || b.Len() == 0 {
		return nil
	}
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.closed {
		return ErrClosed
	}
	for _, chunk := range b.Split(w.MaxRecords) {
		select {
		case w.in <- chunk:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// Sync waits until every batch submitted before it has been committed (or
// dropped by a helper told to stop). An import uses it to report its traces
// only once the app can read them.
func (w *Writer) Sync(ctx context.Context) error {
	marker := &Batch{synced: make(chan struct{})}
	w.mu.RLock()
	if w.closed {
		w.mu.RUnlock()
		return ErrClosed
	}
	select {
	case w.in <- marker:
	case <-ctx.Done():
		w.mu.RUnlock()
		return ctx.Err()
	}
	w.mu.RUnlock()
	select {
	case <-marker.synced:
		return nil
	case <-w.done:
		return ErrClosed
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Prune starts a pruning pass now.
func (w *Writer) Prune() { w.do(func() {}) }

// SetRetention changes the retention and prunes at once.
func (w *Writer) SetRetention(seconds int64) { w.do(func() { w.retentionS = seconds }) }

// do runs f on the writer goroutine, then starts a pruning pass.
func (w *Writer) do(f func()) {
	select {
	case w.ctl <- f:
	case <-w.done:
	}
}

// Close stops intake, commits everything queued and waits for the goroutine.
// CloseWithin is Close with a deadline: batches still queued after d are
// dropped instead of committed, so the helper exits within a second of stdin
// closing even when a flood has filled the queue. It returns how many spans
// and logs were dropped.
func (w *Writer) CloseWithin(d time.Duration) (dropped int) {
	w.stopBy.Store(time.Now().Add(d).UnixNano())
	w.Close()
	return w.dropped
}

func (w *Writer) Close() {
	w.mu.Lock()
	if !w.closed {
		w.closed = true
		close(w.in)
	}
	w.mu.Unlock()
	<-w.done
}

// PruneInterval is how often the writer prunes: every `every`, or every
// retention period when that is shorter, so data never outlives a short
// retention (a test hook's few seconds) by a whole minute.
func PruneInterval(every time.Duration, retentionS int64) time.Duration {
	if retentionS > 0 && retentionS < int64(every/time.Second) {
		return time.Duration(retentionS) * time.Second
	}
	return every
}

// Cutoff is the receive time before which data older than retentionS is
// pruned. A retention too long for int64 nanoseconds (about 292 years)
// prunes nothing instead of overflowing into a cutoff in the future.
func Cutoff(nowNs, retentionS int64) int64 {
	if retentionS > math.MaxInt64/int64(time.Second) {
		return math.MinInt64
	}
	return nowNs - retentionS*int64(time.Second)
}

func (w *Writer) run() {
	defer close(w.done)

	var (
		pending []*Batch
		count   int
		timer   = time.NewTimer(time.Hour)
		timerC  <-chan time.Time
	)
	timer.Stop()

	flush := func() {
		timer.Stop()
		timerC = nil
		if len(pending) == 0 {
			return
		}
		res, err := w.store.Commit(pending)
		pending, count = nil, 0
		if err != nil {
			w.events.Error(err)
			return
		}
		if res.Seq > 0 {
			w.events.Batch(res)
		}
	}
	add := func(b *Batch) {
		if len(pending) == 0 {
			timer.Reset(w.MaxDelay)
			timerC = timer.C
		}
		pending = append(pending, b)
		count += b.Len()
		if count >= w.MaxRecords {
			flush()
		}
	}

	late := func() bool {
		t := w.stopBy.Load()
		return t != 0 && time.Now().UnixNano() > t
	}
	// receive handles one read from the queue and reports whether to go on.
	receive := func(b *Batch, ok bool) bool {
		switch {
		case ok && b.synced != nil:
			flush()
			close(b.synced)
			return true
		case ok && !late():
			add(b)
			return true
		case ok:
			w.dropped += b.Len()
			return true
		case late():
			w.dropped += count
			return false
		default:
			flush()
			return false
		}
	}

	pruneTick := time.NewTicker(PruneInterval(w.PruneEvery, w.retentionS))
	defer pruneTick.Stop()
	var (
		pruning     bool
		pruneCutoff int64
		pruneTotal  PruneResult
	)
	startPrune := func() {
		// A new request while a pass runs restarts it with the newer cutoff.
		if !pruning {
			pruneTotal = PruneResult{}
		}
		pruning = true
		pruneCutoff = Cutoff(w.store.Now(), w.retentionS)
	}
	pruneStep := func() {
		res, done, err := w.store.PruneChunk(pruneCutoff, w.retentionS)
		if err != nil {
			pruning = false
			w.events.Error(err)
			return
		}
		pruneTotal.Add(res)
		if done {
			pruning = false
			if !pruneTotal.Empty() {
				w.events.Pruned(pruneTotal)
			}
		}
	}
	for {
		if pruning {
			// Prune one chunk at a time and let batches in between.
			select {
			case b, ok := <-w.in:
				if !receive(b, ok) {
					return
				}
			case <-timerC:
				flush()
			case f := <-w.ctl:
				f()
				pruneTick.Reset(PruneInterval(w.PruneEvery, w.retentionS))
				startPrune()
			case <-pruneTick.C:
				startPrune()
			default:
				pruneStep()
			}
			continue
		}
		select {
		case b, ok := <-w.in:
			if !receive(b, ok) {
				return
			}
		case <-timerC:
			flush()
		case f := <-w.ctl:
			f()
			pruneTick.Reset(PruneInterval(w.PruneEvery, w.retentionS))
			startPrune()
		case <-pruneTick.C:
			startPrune()
		}
	}
}

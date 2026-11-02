package store

import (
	"encoding/json"
	"strconv"
)

// PruneChunkTraces is how many traces one pruning transaction deletes, so a
// long pruning pass never holds the write lock for long.
const PruneChunkTraces = 500

const pruneChunkLogs = 5000

// PruneChunk deletes up to PruneChunkTraces traces received before cutoff,
// with their spans and logs, then up to a chunk of old logs. done is true when
// nothing older than cutoff is left.
func (s *Store) PruneChunk(cutoff int64, retentionS int64) (res PruneResult, done bool, err error) {
	tx, err := s.db.Begin()
	if err != nil {
		return res, false, err
	}
	defer tx.Rollback()

	rows, err := tx.Stmt(s.stmts.pruneSelect).Query(cutoff, PruneChunkTraces)
	if err != nil {
		return res, false, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return res, false, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return res, false, err
	}

	if len(ids) > 0 {
		list, _ := json.Marshal(ids)
		r, err := tx.Stmt(s.stmts.pruneSpans).Exec(string(list))
		if err != nil {
			return res, false, err
		}
		res.Spans, _ = r.RowsAffected()
		if r, err = tx.Stmt(s.stmts.pruneLogs).Exec(string(list)); err != nil {
			return res, false, err
		}
		res.Logs, _ = r.RowsAffected()
		if r, err = tx.Stmt(s.stmts.pruneTraces).Exec(string(list)); err != nil {
			return res, false, err
		}
		res.Traces, _ = r.RowsAffected()
	}

	// Logs also expire by their own receive time (logs without a trace, or
	// linked to a trace that is still kept).
	r, err := tx.Stmt(s.stmts.pruneOldLog).Exec(cutoff, pruneChunkLogs)
	if err != nil {
		return res, false, err
	}
	oldLogs, _ := r.RowsAffected()
	res.Logs += oldLogs

	done = len(ids) < PruneChunkTraces && oldLogs < pruneChunkLogs
	if done {
		if _, err := tx.Stmt(s.stmts.setMeta).Exec("retention_s", strconv.FormatInt(retentionS, 10)); err != nil {
			return res, false, err
		}
		if _, err := tx.Stmt(s.stmts.setMeta).Exec("last_seq", strconv.FormatInt(s.lastSeq, 10)); err != nil {
			return res, false, err
		}
	}
	return res, done, tx.Commit()
}

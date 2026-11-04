package receiver

import (
	"errors"
	"fmt"

	"google.golang.org/protobuf/encoding/protowire"
)

// MaxValueDepth is how deeply attribute values and log bodies may nest
// (arrays and maps inside each other) in a request. pdata decodes nested
// values recursively, so a value nested two million levels deep overflowed
// the helper's stack and killed it; deeper requests are refused before
// decoding with 400 or InvalidArgument. Values deeper than
// convert.MaxValueDepth (32) are still accepted and stored as a placeholder.
const MaxValueDepth = 64

// maxJSONDepth bounds brackets in an OTLP/JSON body: up to 16 levels of
// request structure around the outermost value (a metric exemplar's
// attribute), then at most four per nested value
// ({"kvlistValue":{"values":[{"key":..,"value":{).
const maxJSONDepth = 16 + 4*MaxValueDepth

var errTooDeep = fmt.Errorf("attribute values or log bodies are nested more than %d levels deep", MaxValueDepth)

var errMalformed = errors.New("malformed protobuf")

// msgType names the OTLP messages on the way from a request to its values.
type msgType uint8

const (
	mOther msgType = iota
	mTraceRequest
	mLogsRequest
	mMetricsRequest
	mResourceSpans
	mResourceLogs
	mResourceMetrics
	mResource
	mScope
	mScopeSpans
	mScopeLogs
	mScopeMetrics
	mSpan
	mSpanEvent
	mSpanLink
	mLogRecord
	mMetric
	mGauge
	mSum
	mHistogram
	mExpHistogram
	mSummary
	mNumberPoint
	mHistogramPoint
	mExpHistogramPoint
	mSummaryPoint
	mExemplar
	mKeyValue
	mAnyValue
	mArrayValue
	mKeyValueList
)

// children maps each message to the fields that hold a message which can
// contain an AnyValue (field numbers from opentelemetry-proto, plus the
// deprecated scope field 1000 pdata still decodes). Other fields are skipped.
var children = [...]map[protowire.Number]msgType{
	mTraceRequest:      {1: mResourceSpans},
	mLogsRequest:       {1: mResourceLogs},
	mMetricsRequest:    {1: mResourceMetrics},
	mResourceSpans:     {1: mResource, 2: mScopeSpans, 1000: mScopeSpans},
	mResourceLogs:      {1: mResource, 2: mScopeLogs, 1000: mScopeLogs},
	mResourceMetrics:   {1: mResource, 2: mScopeMetrics, 1000: mScopeMetrics},
	mResource:          {1: mKeyValue},
	mScope:             {3: mKeyValue},
	mScopeSpans:        {1: mScope, 2: mSpan},
	mScopeLogs:         {1: mScope, 2: mLogRecord},
	mScopeMetrics:      {1: mScope, 2: mMetric},
	mSpan:              {9: mKeyValue, 11: mSpanEvent, 13: mSpanLink},
	mSpanEvent:         {3: mKeyValue},
	mSpanLink:          {5: mKeyValue},
	mLogRecord:         {5: mAnyValue, 6: mKeyValue},
	mMetric:            {5: mGauge, 7: mSum, 9: mHistogram, 10: mExpHistogram, 11: mSummary, 12: mKeyValue},
	mGauge:             {1: mNumberPoint},
	mSum:               {1: mNumberPoint},
	mHistogram:         {1: mHistogramPoint},
	mExpHistogram:      {1: mExpHistogramPoint},
	mSummary:           {1: mSummaryPoint},
	mNumberPoint:       {5: mExemplar, 7: mKeyValue},
	mHistogramPoint:    {8: mExemplar, 9: mKeyValue},
	mExpHistogramPoint: {1: mKeyValue, 11: mExemplar},
	mSummaryPoint:      {7: mKeyValue},
	mExemplar:          {7: mKeyValue},
	mKeyValue:          {2: mAnyValue},
	mAnyValue:          {5: mArrayValue, 6: mKeyValueList},
	mArrayValue:        {1: mAnyValue},
	mKeyValueList:      {1: mKeyValue},
}

// checkProtoDepth walks a protobuf request without recursion and fails when
// values nest more than MaxValueDepth levels, or when the bytes are not
// protobuf at all.
func checkProtoDepth(b []byte, root msgType) error {
	type frame struct {
		typ msgType
		end int
	}
	stack := make([]frame, 1, 16)
	stack[0] = frame{root, len(b)}
	values := 0 // AnyValues on the stack
	pos := 0
	for {
		top := stack[len(stack)-1]
		if pos == top.end {
			if len(stack) == 1 {
				return nil
			}
			if top.typ == mAnyValue {
				values--
			}
			stack = stack[:len(stack)-1]
			continue
		}
		num, typ, n := protowire.ConsumeTag(b[pos:top.end])
		if n < 0 {
			return errMalformed
		}
		pos += n
		if typ == protowire.BytesType {
			if child, ok := children[top.typ][num]; ok {
				l, n := protowire.ConsumeVarint(b[pos:top.end])
				if n < 0 || l > uint64(top.end-pos-n) {
					return errMalformed
				}
				pos += n
				if child == mAnyValue {
					if values++; values > MaxValueDepth {
						return errTooDeep
					}
				}
				stack = append(stack, frame{child, pos + int(l)})
				continue
			}
		}
		n = protowire.ConsumeFieldValue(num, typ, b[pos:top.end])
		if n < 0 {
			return errMalformed
		}
		pos += n
	}
}

// checkJSONDepth fails when brackets in a JSON body nest deeper than
// maxJSONDepth. Brackets inside strings do not count; anything else that is
// not valid JSON is left for the decoder to reject.
func checkJSONDepth(b []byte) error {
	depth := 0
	inString := false
	for i := 0; i < len(b); i++ {
		c := b[i]
		if inString {
			switch c {
			case '\\':
				i++
			case '"':
				inString = false
			}
			continue
		}
		switch c {
		case '"':
			inString = true
		case '{', '[':
			if depth++; depth > maxJSONDepth {
				return errTooDeep
			}
		case '}', ']':
			depth--
		}
	}
	return nil
}

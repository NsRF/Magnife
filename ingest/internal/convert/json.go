// Package convert turns OTLP pdata into store rows, encoding attributes,
// events and links as the JSON documented in docs/schema.sql.
package convert

import (
	"encoding/base64"
	"math"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"go.opentelemetry.io/collector/pdata/pcommon"
)

const hexDigits = "0123456789abcdef"

// appendString appends s as a JSON string. Invalid UTF-8 becomes U+FFFD.
func appendString(b []byte, s string) []byte {
	b = append(b, '"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			if c >= 0x20 && c != '"' && c != '\\' {
				i++
				continue
			}
			b = append(b, s[start:i]...)
			switch c {
			case '"', '\\':
				b = append(b, '\\', c)
			case '\n':
				b = append(b, '\\', 'n')
			case '\r':
				b = append(b, '\\', 'r')
			case '\t':
				b = append(b, '\\', 't')
			default:
				b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
			}
			i++
			start = i
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			b = append(b, s[start:i]...)
			b = append(b, `�`...)
			i += size
			start = i
			continue
		}
		i += size
	}
	b = append(b, s[start:]...)
	return append(b, '"')
}

// appendValue appends an AnyValue: string, number, bool, array, object,
// base64 bytes or null. Non-finite doubles, which JSON cannot hold, become
// the strings "NaN", "+Inf" and "-Inf".
func appendValue(b []byte, v pcommon.Value) []byte {
	switch v.Type() {
	case pcommon.ValueTypeStr:
		return appendString(b, v.Str())
	case pcommon.ValueTypeInt:
		return strconv.AppendInt(b, v.Int(), 10)
	case pcommon.ValueTypeDouble:
		f := v.Double()
		switch {
		case math.IsNaN(f):
			return append(b, `"NaN"`...)
		case math.IsInf(f, 1):
			return append(b, `"+Inf"`...)
		case math.IsInf(f, -1):
			return append(b, `"-Inf"`...)
		}
		return strconv.AppendFloat(b, f, 'g', -1, 64)
	case pcommon.ValueTypeBool:
		return strconv.AppendBool(b, v.Bool())
	case pcommon.ValueTypeMap:
		return appendMap(b, v.Map())
	case pcommon.ValueTypeSlice:
		s := v.Slice()
		b = append(b, '[')
		for i := 0; i < s.Len(); i++ {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendValue(b, s.At(i))
		}
		return append(b, ']')
	case pcommon.ValueTypeBytes:
		b = append(b, '"')
		b = base64.StdEncoding.AppendEncode(b, v.Bytes().AsRaw())
		return append(b, '"')
	default:
		return append(b, "null"...)
	}
}

type entry struct {
	key string
	val pcommon.Value
}

// sortedEntries returns the map's entries sorted by key, keeping the last
// value of a repeated key.
func sortedEntries(m pcommon.Map) []entry {
	es := make([]entry, 0, m.Len())
	m.Range(func(k string, v pcommon.Value) bool {
		es = append(es, entry{k, v})
		return true
	})
	slices.SortStableFunc(es, func(a, b entry) int { return strings.Compare(a.key, b.key) })
	out := es[:0]
	for i, e := range es {
		if i+1 < len(es) && es[i+1].key == e.key {
			continue
		}
		out = append(out, e)
	}
	return out
}

// appendMap appends an object with sorted, unique keys, so equal attribute
// sets always encode to the same bytes (the resource hash relies on it).
func appendMap(b []byte, m pcommon.Map) []byte {
	b = append(b, '{')
	for i, e := range sortedEntries(m) {
		if i > 0 {
			b = append(b, ',')
		}
		b = appendString(b, e.key)
		b = append(b, ':')
		b = appendValue(b, e.val)
	}
	return append(b, '}')
}

// Attributes encodes an attribute map and returns its unique keys.
func Attributes(m pcommon.Map) (string, []string) {
	if m.Len() == 0 {
		return "{}", nil
	}
	es := sortedEntries(m)
	keys := make([]string, len(es))
	b := make([]byte, 0, 64*len(es))
	b = append(b, '{')
	for i, e := range es {
		if i > 0 {
			b = append(b, ',')
		}
		keys[i] = e.key
		b = appendString(b, e.key)
		b = append(b, ':')
		b = appendValue(b, e.val)
	}
	b = append(b, '}')
	return string(b), keys
}

// ValueJSON encodes one AnyValue.
func ValueJSON(v pcommon.Value) string { return string(appendValue(nil, v)) }

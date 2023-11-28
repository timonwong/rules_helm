package main

import (
	"io"
	"strings"
)

// TagFunc can be used as a substitution value in the map passed to Execute*.
// Execute* functions pass tag (placeholder) name in 'tag' argument.
//
// TagFunc must be safe to call from concurrently running goroutines.
//
// TagFunc must write contents to w and return the number of bytes written.
type TagFunc func(w io.Writer, tag string) (int, error)

// ExecuteFunc calls f on each template tag (placeholder) occurrence.
//
// Returns the number of bytes written to w.
//
// This function is optimized for constantly changing templates.
// Use Template.ExecuteFunc for frozen templates.
func ExecuteFunc(template, startTag, endTag string, w io.Writer, f TagFunc) (int64, error) {
	s := template

	var nn int64
	var ni int
	var err error
	for {
		n := strings.Index(s, startTag)
		if n < 0 {
			break
		}
		ni, err = io.WriteString(w, s[:n])
		nn += int64(ni)
		if err != nil {
			return nn, err
		}

		s = s[n+len(startTag):]
		n = strings.Index(s, endTag)
		if n < 0 {
			// cannot find end tag - just write it to the output.
			ni, _ = io.WriteString(w, startTag)
			nn += int64(ni)
			break
		}

		ni, err = f(w, string(s[:n]))
		nn += int64(ni)
		if err != nil {
			return nn, err
		}
		s = s[n+len(endTag):]
	}
	ni, err = io.WriteString(w, s)
	nn += int64(ni)

	return nn, err
}

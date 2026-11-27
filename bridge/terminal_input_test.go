package main

import (
	"reflect"
	"testing"
)

func TestParseInputKeepsMouseReportsRaw(t *testing.T) {
	got := parseInput("\x1b[<64;26;24M")
	want := []inputOp{{text: "\x1b[<64;26;24M"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseInput = %#v, want %#v", got, want)
	}
}

func TestParseInputKeepsRepeatedMouseReportsTogether(t *testing.T) {
	got := parseInput("\x1b[<64;26;24M\x1b[<64;26;24M\x1b[<65;26;24m")
	want := []inputOp{{text: "\x1b[<64;26;24M\x1b[<64;26;24M\x1b[<65;26;24m"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseInput = %#v, want %#v", got, want)
	}
}

func TestParseInputKeepsX10MouseReportsRaw(t *testing.T) {
	got := parseInput("\x1b[M`&&")
	want := []inputOp{{text: "\x1b[M`&&"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseInput = %#v, want %#v", got, want)
	}
}

func TestParseInputStillNamesKeys(t *testing.T) {
	cases := []struct {
		in   string
		want []inputOp
	}{
		{"a", []inputOp{{text: "a"}}},
		{"\x1b[A", []inputOp{{key: "up"}}},
		{"\x1b[1;5C", []inputOp{{key: "ctrl-right"}}},
		{"\x1bOP", []inputOp{{key: "f1"}}},
		{"\r", []inputOp{{key: "enter"}}},
		{"\t", []inputOp{{key: "tab"}}},
		{"\x7f", []inputOp{{key: "backspace"}}},
		{"\x01", []inputOp{{key: "ctrl-a"}}},
		{"\x1b", []inputOp{{key: "esc"}}},
		{"hi\x1b[A!", []inputOp{{text: "hi"}, {key: "up"}, {text: "!"}}},
	}
	for _, tc := range cases {
		if got := parseInput(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("parseInput(%q) = %#v, want %#v", tc.in, got, tc.want)
		}
	}
}

func TestParseInputDropsBracketedPasteMarkers(t *testing.T) {
	got := parseInput("\x1b[200~ls -la\x1b[201~")
	want := []inputOp{{text: "ls -la"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseInput = %#v, want %#v", got, want)
	}
}

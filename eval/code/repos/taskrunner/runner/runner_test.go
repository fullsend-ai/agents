package runner

import (
	"context"
	"testing"

	"github.com/eval-org/taskrunner/config"
)

func TestNewRejectsInvalidConfig(t *testing.T) {
	cases := []struct {
		name string
		cfg  config.Config
	}{
		{"zero workers", config.Config{Workers: 0, Timeout: 1, MaxRetries: 0}},
		{"negative timeout", config.Config{Workers: 1, Timeout: -1, MaxRetries: 0}},
		{"negative retries", config.Config{Workers: 1, Timeout: 1, MaxRetries: -1}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := New(tc.cfg)
			if err == nil {
				t.Errorf("New(%+v) = nil error, want error", tc.cfg)
			}
		})
	}
}

func TestRunHappyPath(t *testing.T) {
	r, err := New(config.Config{Workers: 1, Timeout: 5, MaxRetries: 0})
	if err != nil {
		t.Fatal(err)
	}
	called := false
	r.Register(Task{Name: "test", Fn: func(ctx context.Context) error {
		called = true
		return nil
	}})
	if err := r.Run(); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Error("task was not executed")
	}
}

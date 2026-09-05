package runner

import (
	"context"
	"errors"
	"sync/atomic"
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

func TestRunRetriesUntilSuccess(t *testing.T) {
	r, err := New(config.Config{Workers: 1, Timeout: 5, MaxRetries: 3})
	if err != nil {
		t.Fatal(err)
	}
	var attempts int32
	r.Register(Task{Name: "flaky", Fn: func(ctx context.Context) error {
		if atomic.AddInt32(&attempts, 1) < 3 {
			return errors.New("transient")
		}
		return nil
	}})
	if err := r.Run(); err != nil {
		t.Fatalf("Run() = %v, want nil after retries", err)
	}
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Errorf("attempts = %d, want 3", got)
	}
}

func TestRunTimeoutCancelsAttempt(t *testing.T) {
	r, err := New(config.Config{Workers: 1, Timeout: 1, MaxRetries: 0})
	if err != nil {
		t.Fatal(err)
	}
	r.Register(Task{Name: "hang", Fn: func(ctx context.Context) error {
		<-ctx.Done()
		return ctx.Err()
	}})
	if err := r.Run(); err == nil {
		t.Fatal("Run() = nil, want error from timed-out task")
	}
}

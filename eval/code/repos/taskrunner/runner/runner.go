package runner

import (
	"context"
	"fmt"
	"time"

	"github.com/eval-org/taskrunner/config"
)

// Task represents a unit of work to execute.
type Task struct {
	Name string
	Fn   func(context.Context) error
}

// Runner executes tasks according to the provided configuration.
type Runner struct {
	cfg   config.Config
	tasks []Task
}

// New creates a Runner with the given configuration.
func New(cfg config.Config) (*Runner, error) {
	if cfg.Workers < 1 {
		return nil, fmt.Errorf("workers must be >= 1, got %d", cfg.Workers)
	}
	if cfg.Timeout < 1 {
		return nil, fmt.Errorf("timeout must be >= 1, got %d", cfg.Timeout)
	}
	if cfg.MaxRetries < 0 {
		return nil, fmt.Errorf("max_retries must be >= 0, got %d", cfg.MaxRetries)
	}
	return &Runner{cfg: cfg}, nil
}

// Register adds a task to the runner.
func (r *Runner) Register(t Task) {
	r.tasks = append(r.tasks, t)
}

// Run executes all registered tasks with retry and timeout logic.
// It processes tasks concurrently based on the runner's configuration.
func (r *Runner) Run() error {
	sem := make(chan struct{}, r.cfg.Workers)
	errs := make(chan error, len(r.tasks))

	for _, task := range r.tasks {
		sem <- struct{}{}
		go func(t Task) {
			defer func() { <-sem }()
			errs <- r.runWithRetry(t)
		}(task)
	}

	for range r.tasks {
		if err := <-errs; err != nil {
			return err
		}
	}
	return nil
}

func (r *Runner) runWithRetry(t Task) error {
	timeout := time.Duration(r.cfg.Timeout) * time.Second
	var lastErr error

	for attempt := 0; attempt <= r.cfg.MaxRetries; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		err := t.Fn(ctx)
		cancel()

		if err == nil {
			return nil
		}
		lastErr = err
	}
	return fmt.Errorf("task %s failed after %d retries: %w", t.Name, r.cfg.MaxRetries, lastErr)
}

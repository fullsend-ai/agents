package runner

import (
	"fmt"
	"time"

	"github.com/eval-org/taskrunner/config"
)

// Task represents a unit of work to execute.
type Task struct {
	Name string
	Fn   func() error
}

// Runner executes tasks according to the provided configuration.
type Runner struct {
	cfg   config.Config
	tasks []Task
}

// New creates a Runner with the given configuration.
func New(cfg config.Config) *Runner {
	return &Runner{cfg: cfg}
}

// Register adds a task to the runner.
func (r *Runner) Register(t Task) {
	r.tasks = append(r.tasks, t)
}

// Run executes all registered tasks with retry and timeout logic.
// It uses cfg.MaxRetries, cfg.Timeout, and cfg.Workers.
// Note: cfg.VerboseLogging is not checked anywhere — this is dead config.
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
		done := make(chan error, 1)
		go func() { done <- t.Fn() }()

		select {
		case err := <-done:
			if err == nil {
				return nil
			}
			lastErr = err
		case <-time.After(timeout):
			lastErr = fmt.Errorf("task %s timed out after %v", t.Name, timeout)
		}
	}
	return fmt.Errorf("task %s failed after %d retries: %w", t.Name, r.cfg.MaxRetries, lastErr)
}

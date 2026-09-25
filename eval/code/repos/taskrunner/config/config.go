package config

import (
	"fmt"
	"os"

	"github.com/eval-org/taskrunner/config/internal/yaml"
)

// Config holds the task runner configuration.
type Config struct {
	// MaxRetries controls how many times a failed task is retried.
	MaxRetries int `yaml:"max_retries"`

	// Timeout is the per-task timeout in seconds.
	Timeout int `yaml:"timeout"`

	// VerboseLogging enables detailed debug output.
	VerboseLogging bool `yaml:"verbose_logging"`

	// Workers is the number of concurrent task workers.
	Workers int `yaml:"workers"`
}

// Defaults returns a Config with sensible default values.
func Defaults() Config {
	return Config{
		MaxRetries:     3,
		Timeout:        60,
		VerboseLogging: false,
		Workers:        4,
	}
}

// Load reads a YAML config file and returns a Config.
// Missing fields are filled with defaults.
func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("reading config %s: %w", path, err)
	}
	cfg := Defaults()
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parsing config %s: %w", path, err)
	}
	return cfg, nil
}

package config

import "github.com/eval-org/taskrunner/config/internal/yaml"

// SetField implements the configFields interface for the minimal YAML parser.
func (c *Config) SetField(key, value string) error {
	switch key {
	case "max_retries":
		v, err := yaml.ParseInt(value)
		if err != nil {
			return err
		}
		c.MaxRetries = v
	case "timeout":
		v, err := yaml.ParseInt(value)
		if err != nil {
			return err
		}
		c.Timeout = v
	case "verbose_logging":
		v, err := yaml.ParseBool(value)
		if err != nil {
			return err
		}
		c.VerboseLogging = v
	case "workers":
		v, err := yaml.ParseInt(value)
		if err != nil {
			return err
		}
		c.Workers = v
	}
	return nil
}

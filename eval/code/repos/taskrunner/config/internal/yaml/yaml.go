package yaml

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Unmarshal is a minimal YAML parser for flat key-value configs.
// It supports string, int, and bool values only.
func Unmarshal(data []byte, v interface{}) error {
	lines := strings.Split(string(data), "\n")
	kvs := make(map[string]string)
	re := regexp.MustCompile(`^(\w+):\s*(.+)$`)
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := re.FindStringSubmatch(line)
		if m == nil {
			return fmt.Errorf("line %d: malformed YAML (expected 'key: value'): %q", i+1, line)
		}
		kvs[m[1]] = m[2]
	}
	return applyToStruct(kvs, v)
}

func applyToStruct(kvs map[string]string, v interface{}) error {
	type configFields interface {
		SetField(key, value string) error
	}
	if s, ok := v.(configFields); ok {
		for k, val := range kvs {
			if err := s.SetField(k, val); err != nil {
				return err
			}
		}
		return nil
	}
	return fmt.Errorf("target does not implement configFields interface")
}

// ParseBool parses a YAML boolean string.
func ParseBool(s string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true", "yes", "on":
		return true, nil
	case "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("invalid bool: %q", s)
	}
}

// ParseInt parses a YAML integer string.
func ParseInt(s string) (int, error) {
	return strconv.Atoi(strings.TrimSpace(s))
}

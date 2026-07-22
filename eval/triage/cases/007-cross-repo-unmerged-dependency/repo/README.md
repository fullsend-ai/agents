# Config Parser

A configuration file parser that reads YAML config files and validates
them against a known schema format.

## Dependencies

- `upstream-lib` — provides schema definitions and validation utilities.
  Config files must conform to the schema format defined by upstream-lib.

## Usage

```bash
./bin/parse-config config.yaml
```

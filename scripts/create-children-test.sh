#!/usr/bin/env bash
# create-children-test.sh — Unit tests for jira-project-schema helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jira-project-schema.sh
source "${SCRIPT_DIR}/jira-project-schema.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_eq() {
  local name="$1" expected="$2" actual="$3"
  local e a
  e=$(echo "$expected" | jq -cS .)
  a=$(echo "$actual" | jq -cS .)
  assert_eq "$name" "$e" "$a"
}

echo "=== jira-project-schema tests ==="

# --- intersect: no filter keeps live ---
LIVE='[{"name":"Epic"},{"name":"Story"},{"name":"Task"}]'
got=$(jira_schema_intersect_issue_types "$LIVE" "")
assert_json_eq "intersect no filter" "$LIVE" "$got"

# --- intersect: Epic+Task only ---
got=$(jira_schema_intersect_issue_types "$LIVE" '["Epic","Task"]')
assert_json_eq "intersect Epic+Task" '[{"name":"Epic"},{"name":"Task"}]' "$got"

# --- intersect: case insensitive ---
got=$(jira_schema_intersect_issue_types "$LIVE" '["epic","TASK"]')
assert_json_eq "intersect case-insensitive" '[{"name":"Epic"},{"name":"Task"}]' "$got"

# --- intersect: empty intersection ---
got=$(jira_schema_intersect_issue_types "$LIVE" '["Sub-task"]')
assert_json_eq "intersect empty" '[]' "$got"

# --- filter custom fields ---
PLAN='{"customfield_1":{"id":"1"},"customfield_evil":true,"customfield_2":"x"}'
got=$(jira_schema_filter_custom_fields "$PLAN" '["customfield_1","customfield_2"]' 2>/dev/null)
assert_json_eq "filter allowlist" '{"customfield_1":{"id":"1"},"customfield_2":"x"}' "$got"

got=$(jira_schema_filter_custom_fields "$PLAN" '[]' 2>/dev/null)
assert_json_eq "filter empty allowlist drops all" '{}' "$got"

got=$(jira_schema_filter_custom_fields 'null' '["customfield_1"]' 2>/dev/null)
assert_json_eq "filter null plan" '{}' "$got"

# Reserved fields always stripped even if allowlisted
PLAN_RES='{"customfield_1":{"id":"1"},"summary":"HACK","project":{"key":"EVIL"},"description":"x"}'
got=$(jira_schema_filter_custom_fields "$PLAN_RES" '["customfield_1","summary","project","description"]' 2>/dev/null)
assert_json_eq "filter strips reserved" '{"customfield_1":{"id":"1"}}' "$got"

# Invalid project keys rejected
if jira_schema_valid_project_key "RHIDP"; then
  assert_eq "valid project key RHIDP" "1" "1"
else
  assert_eq "valid project key RHIDP" "1" "0"
fi
if jira_schema_valid_project_key "../etc"; then
  assert_eq "invalid path key rejected" "0" "1"
else
  assert_eq "invalid path key rejected" "1" "1"
fi
if jira_schema_valid_project_key "rhidp"; then
  assert_eq "lowercase key rejected" "0" "1"
else
  assert_eq "lowercase key rejected" "1" "1"
fi

# --- allowlist keys from config ---
CFG='{"projects":{"RHIDP":{"fields":{"customfield_12345":{"name":"Team"}}},"STONEBLD":{"fields":{}}},"default_fields":{"customfield_99":{}}}'
got=$(jira_schema_allowlist_keys_for_project "$CFG" "RHIDP")
assert_json_eq "allowlist keys RHIDP" '["customfield_12345","customfield_99"]' "$got"

got=$(jira_schema_allowed_types_for_project "$CFG" "RHIDP")
# Missing allowed_issue_types → empty array (not blank stdout)
assert_eq "allowed types missing → empty array" "[]" "$got"

CFG2='{"projects":{"RHIDP":{"allowed_issue_types":["Epic","Task"],"fields":{}}}}'
got=$(jira_schema_allowed_types_for_project "$CFG2" "RHIDP")
assert_json_eq "allowed types present" '["Epic","Task"]' "$got"

# --- candidates ---
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
# Routing
Use RHIDP for features and STONEBLD for build work.
EOF
keys=$(jira_schema_candidate_project_keys "KONFLUX" "$CFG" "$TMP" | tr '\n' ' ')
assert_eq "candidates include parent+config+skill" "1" "$(echo "$keys" | grep -c KONFLUX || true)"
assert_eq "candidates include RHIDP" "1" "$(echo "$keys" | grep -c RHIDP || true)"
assert_eq "candidates include STONEBLD" "1" "$(echo "$keys" | grep -c STONEBLD || true)"
rm -f "$TMP"

# --- build routable with mocks ---
MOCK_DIR=$(mktemp -d)
echo '[{"name":"Epic"},{"name":"Story"},{"name":"Task"},{"name":"Bug"}]' > "${MOCK_DIR}/RHIDP.json"
echo '[{"name":"Feature"},{"name":"Epic"},{"name":"Story"}]' > "${MOCK_DIR}/KONFLUX.json"
export JIRA_SCHEMA_TYPES_MOCK_DIR="$MOCK_DIR"

CFG3='{"projects":{"RHIDP":{"allowed_issue_types":["Epic","Task"],"fields":{"customfield_1":{}}}}}'
rp=$(jira_schema_build_routable_projects "KONFLUX" "$CFG3" "")
usable=$(echo "$rp" | jq -c '.RHIDP.usable_issue_types')
assert_json_eq "routable RHIDP usable Epic+Task" '[{"name":"Epic"},{"name":"Task"}]' "$usable"
konflux_usable=$(echo "$rp" | jq -c '[.KONFLUX.usable_issue_types[].name]')
assert_json_eq "routable parent all live types" '["Feature","Epic","Story"]' "$konflux_usable"
fields=$(echo "$rp" | jq -c '.RHIDP.allowed_custom_fields')
assert_json_eq "routable allowlisted fields" '["customfield_1"]' "$fields"
teams=$(echo "$rp" | jq -c '.RHIDP.team_values')
assert_json_eq "routable team_values default empty" '{}' "$teams"
guidance=$(echo "$rp" | jq -c '.RHIDP.custom_field_guidance')
assert_json_eq "routable field guidance from fields" '{"customfield_1":{}}' "$guidance"

CFG4='{"projects":{"RHIDP":{"allowed_issue_types":["Epic","Task"],"fields":{"customfield_1":{"name":"Team","value_type":"string"}},"team_values":{"UI":"abc-123"}}}}'
rp4=$(jira_schema_build_routable_projects "KONFLUX" "$CFG4" "")
assert_json_eq "routable team_values passthrough" '{"UI":"abc-123"}' "$(echo "$rp4" | jq -c '.RHIDP.team_values')"
assert_json_eq "routable field guidance passthrough" '{"customfield_1":{"name":"Team","value_type":"string"}}' "$(echo "$rp4" | jq -c '.RHIDP.custom_field_guidance')"

# --- merge into issue context ---
CTX=$(mktemp)
echo '{"key":"KONFLUX-1","project":{"key":"KONFLUX"}}' > "$CTX"
jira_schema_merge_routable_into_issue_context "$CTX" "$rp"
merged=$(jq -r '.routable_projects.RHIDP.usable_issue_types | length' "$CTX")
assert_eq "merge routable_projects into context" "2" "$merged"

rm -rf "$MOCK_DIR" "$CTX"
unset JIRA_SCHEMA_TYPES_MOCK_DIR

# Priority mapping: empty → empty (no API default)
assert_eq "map empty priority" "" "$(jira_schema_map_priority "")"
assert_eq "map medium priority → Major" "Major" "$(jira_schema_map_priority "medium")"
assert_eq "map high priority → Critical" "Critical" "$(jira_schema_map_priority "High")"
assert_eq "map low priority → Minor" "Minor" "$(jira_schema_map_priority "low")"

# load_config return status
TMPCFG=$(mktemp)
echo '{bad' > "$TMPCFG"
if jira_schema_load_config "$TMPCFG" >/dev/null 2>&1; then
  assert_eq "invalid config returns failure" "0" "1"
else
  assert_eq "invalid config returns failure" "1" "1"
fi
echo '{"projects":{}}' > "$TMPCFG"
if jira_schema_load_config "$TMPCFG" >/dev/null 2>&1; then
  assert_eq "valid config returns success" "1" "1"
else
  assert_eq "valid config returns success" "0" "1"
fi
rm -f "$TMPCFG"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

// Package integration defines the integration test scenarios run in CI.
package integration

// Scenario describes one integration test run. The pipeline that runs
// the scenario is read from PipelinePath in GitURL at Revision.
type Scenario struct {
	Name         string
	GitURL       string
	Revision     string
	PipelinePath string
}

// Scenarios lists every integration test scenario run against a build.
var Scenarios = []Scenario{
	{
		Name:         "test-hello",
		GitURL:       "https://github.com/example-org/testrepo",
		Revision:     "3f9c2a1d8e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a",
		PipelinePath: "integration-tests/test-hello-pipeline.yaml",
	},
}

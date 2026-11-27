// Command eval runs the clinical evaluation harness against the model endpoint
// configured by AGENT_MODEL_* environment variables. Synthetic vignettes only.
// Exit status is non-zero when any metric misses its threshold. Not run in CI.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/markolonius/housecall/backend/internal/agent"
	"github.com/markolonius/housecall/backend/internal/eval"
)

func main() {
	os.Exit(run())
}

func run() int {
	casesDir := flag.String("cases", "evals/cases", "directory of case JSON files")
	resultsDir := flag.String("results", "evals/results", "directory for result files")
	thresholdsPath := flag.String("thresholds", "evals/thresholds.json", "thresholds file")
	rulesOnly := flag.Bool("rules-only", false, "measure emergent recall from red-flag rules alone (model forced to fail)")
	flag.Parse()

	if *rulesOnly {
		fmt.Fprintln(os.Stderr, "eval: --rules-only is not implemented until Phase 4 (red-flag rules)")
		return 2
	}

	cases, err := eval.LoadCases(*casesDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "eval: load cases:", err)
		return 2
	}
	th, err := eval.LoadThresholds(*thresholdsPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "eval: load thresholds:", err)
		return 2
	}

	cfg := agent.ClientConfigFromEnv()
	if err := agent.ValidateEndpoint(cfg.BaseURL, os.Getenv("APP_ENV")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	res := eval.Run(context.Background(), agent.NewClient(cfg, nil), cfg.Model, cases, th)

	path, err := eval.WriteResult(*resultsDir, res)
	if err != nil {
		fmt.Fprintln(os.Stderr, "eval: write result:", err)
		return 2
	}
	fmt.Print(eval.Summary(res))
	fmt.Println("result file:", path)
	if !res.Passed {
		return 1
	}
	return 0
}

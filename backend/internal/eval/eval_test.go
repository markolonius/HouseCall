package eval_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/markolonius/housecall/backend/internal/agent"
	"github.com/markolonius/housecall/backend/internal/eval"
)

// fakeModel answers by inspecting the system prompt and the last user turn.
func fakeModel(t *testing.T, soapReply string) *agent.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []agent.Message `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		reply := ""
		switch req.Messages[0].Content {
		case agent.TriageSystemPrompt:
			last := req.Messages[len(req.Messages)-1].Content
			if strings.Contains(last, "crushing") {
				reply = agent.EmergentMarker
			} else {
				reply = agent.RoutineMarker
			}
		case agent.SOAPDraftSystemPrompt:
			reply = soapReply
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{{"message": map[string]any{"content": reply}}},
		})
	}))
	t.Cleanup(srv.Close)
	return agent.NewClient(agent.ClientConfig{BaseURL: srv.URL, Model: "fake/model:1"}, srv.Client())
}

const goodSOAP = "SUBJECTIVE:\nDull headache for three days.\nOBJECTIVE:\nNone reported\nASSESSMENT:\nPreliminary assessment: tension-type headache; physician review required.\nPLAN:\nHydration and follow up."

const badSOAP = "SUBJECTIVE:\nDull headache.\nOBJECTIVE:\nLungs clear to auscultation, no wheezing.\nASSESSMENT:\nPreliminary assessment: headache.\nPLAN:\nRest."

var thresholds = eval.Thresholds{
	EmergentRecallMin: 1, FalseEmergentRateMax: 0.15,
	StructuredOutputValidityMin: 1, SOAPObjectiveFidelityMin: 1,
}

func loadExamples(t *testing.T) []eval.Case {
	t.Helper()
	cases, err := eval.LoadCases(filepath.Join("..", "..", "evals", "cases"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 4 {
		t.Fatalf("expected example cases, got %d", len(cases))
	}
	return cases
}

func TestRun_PassesWithFaithfulModel(t *testing.T) {
	res := eval.Run(context.Background(), fakeModel(t, goodSOAP), "fake", loadExamples(t), thresholds)
	if !res.Passed {
		t.Fatalf("expected pass:\n%s", eval.Summary(res))
	}
	if v := res.Metrics["emergent_recall"].Value; v == nil || *v != 1 {
		t.Fatalf("emergent recall = %v", v)
	}
	if res.PromptVersions["triage"] != agent.TriageSystemPromptVersion {
		t.Fatal("prompt versions missing")
	}
}

func TestRun_FailsOnFabricatedObjective(t *testing.T) {
	res := eval.Run(context.Background(), fakeModel(t, badSOAP), "fake", loadExamples(t), thresholds)
	if res.Passed || res.Metrics["soap_objective_fidelity"].Passed {
		t.Fatalf("expected fidelity failure:\n%s", eval.Summary(res))
	}
}

func TestRun_ModelDownMissesEmergent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	mc := agent.NewClient(agent.ClientConfig{BaseURL: srv.URL, Model: "m"}, srv.Client())
	res := eval.Run(context.Background(), mc, "m", loadExamples(t), thresholds)
	if res.Passed || res.Metrics["emergent_recall"].Passed || res.Metrics["structured_output_validity"].Passed {
		t.Fatalf("expected failures:\n%s", eval.Summary(res))
	}
}

func TestObjectiveViolations_VignetteMentionedIsAllowed(t *testing.T) {
	c := eval.Case{Turns: []agent.Message{{Role: "user", Content: "My doctor heard a murmur last year."}}}
	if v := eval.ObjectiveViolations("Reports prior murmur.", c); len(v) != 0 {
		t.Fatalf("unexpected violations %v", v)
	}
	if v := eval.ObjectiveViolations("Wheezing on auscultation.", c); len(v) != 2 {
		t.Fatalf("violations = %v", v)
	}
}

func TestWriteResult_FileNameAndContent(t *testing.T) {
	res := eval.Run(context.Background(), fakeModel(t, goodSOAP), "fake/model:1", loadExamples(t), thresholds)
	path, err := eval.WriteResult(t.TempDir(), res)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, "-fake-model-1.json") {
		t.Fatalf("path %s", path)
	}
	data, _ := os.ReadFile(path)
	var back eval.Result
	if err := json.Unmarshal(data, &back); err != nil || back.Model != "fake/model:1" || len(back.Cases) != len(res.Cases) {
		t.Fatalf("bad result file: %v", err)
	}
}

func TestLoadCases_RejectsInvalid(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "x.json"), []byte(`{"id":"a","kind":"triage","turns":[{"role":"user","content":"x"}]}`), 0o644)
	if _, err := eval.LoadCases(dir); err == nil {
		t.Fatal("expected error for missing expected_triage")
	}
}

func TestLoadThresholds_Repo(t *testing.T) {
	th, err := eval.LoadThresholds(filepath.Join("..", "..", "evals", "thresholds.json"))
	if err != nil || th.EmergentRecallMin != 1 || th.FalseEmergentRateMax != 0.15 {
		t.Fatalf("thresholds %+v err %v", th, err)
	}
}

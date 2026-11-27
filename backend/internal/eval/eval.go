// Package eval is the clinical evaluation harness: it loads synthetic
// vignettes, runs them through the real agent triage and SOAP code paths
// against a model endpoint, computes the safety metrics and checks them
// against reviewable thresholds. Vignettes are synthetic only; results never
// contain model output, only labels and rule names.
package eval

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/markolonius/housecall/backend/internal/agent"
)

// Case kinds.
const (
	KindTriage        = "triage"
	KindInterviewSOAP = "interview_soap"
)

// Expected triage labels.
const (
	Emergent = "EMERGENT"
	Routine  = "ROUTINE"
)

// Case is one synthetic vignette. See backend/evals/README.md.
type Case struct {
	ID          string          `json:"id"`
	Kind        string          `json:"kind"`
	Description string          `json:"description,omitempty"`
	ReviewedBy  string          `json:"reviewed_by"` // empty until a physician signs off
	Turns       []agent.Message `json:"turns"`

	// triage
	ExpectedTriage string `json:"expected_triage,omitempty"`

	// interview_soap
	RequiredSections        []string `json:"required_sections,omitempty"`          // subset of SUBJECTIVE/OBJECTIVE/ASSESSMENT/PLAN
	MustInclude             []string `json:"must_include,omitempty"`               // facts (case-insensitive substrings) the note must contain
	MustNotInclude          []string `json:"must_not_include,omitempty"`           // facts the note must not contain
	ObjectiveMustNotContain []string `json:"objective_must_not_contain,omitempty"` // extra exam-finding terms banned from Objective
}

// Validate reports a structural problem with the case.
func (c Case) Validate() error {
	if strings.TrimSpace(c.ID) == "" {
		return fmt.Errorf("case has no id")
	}
	if len(c.Turns) == 0 {
		return fmt.Errorf("case %s has no turns", c.ID)
	}
	for _, t := range c.Turns {
		if t.Role != "user" && t.Role != "assistant" {
			return fmt.Errorf("case %s: turn role must be user or assistant", c.ID)
		}
	}
	switch c.Kind {
	case KindTriage:
		if c.ExpectedTriage != Emergent && c.ExpectedTriage != Routine {
			return fmt.Errorf("case %s: expected_triage must be EMERGENT or ROUTINE", c.ID)
		}
	case KindInterviewSOAP:
		for _, s := range c.RequiredSections {
			if !validSection(s) {
				return fmt.Errorf("case %s: unknown required section %q", c.ID, s)
			}
		}
	default:
		return fmt.Errorf("case %s: unknown kind %q", c.ID, c.Kind)
	}
	return nil
}

func validSection(s string) bool {
	switch s {
	case "SUBJECTIVE", "OBJECTIVE", "ASSESSMENT", "PLAN":
		return true
	}
	return false
}

// LoadCases reads every *.json file in dir. A file holds one case object or
// an array of cases. Case ids must be unique. Results are sorted by id.
func LoadCases(dir string) ([]Case, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	var cases []Case
	seen := map[string]bool{}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var batch []Case
		if strings.HasPrefix(strings.TrimSpace(string(data)), "[") {
			err = json.Unmarshal(data, &batch)
		} else {
			var one Case
			err = json.Unmarshal(data, &one)
			batch = []Case{one}
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
		for _, c := range batch {
			if err := c.Validate(); err != nil {
				return nil, fmt.Errorf("%s: %w", filepath.Base(f), err)
			}
			if seen[c.ID] {
				return nil, fmt.Errorf("duplicate case id %s", c.ID)
			}
			seen[c.ID] = true
			cases = append(cases, c)
		}
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].ID < cases[j].ID })
	return cases, nil
}

// Thresholds are the pass/fail gates, loaded from evals/thresholds.json.
type Thresholds struct {
	EmergentRecallMin           float64 `json:"emergent_recall_min"`
	FalseEmergentRateMax        float64 `json:"false_emergent_rate_max"`
	StructuredOutputValidityMin float64 `json:"structured_output_validity_min"`
	SOAPObjectiveFidelityMin    float64 `json:"soap_objective_fidelity_min"`
	RulesOnlyEmergentRecallMin  float64 `json:"rules_only_emergent_recall_min"` // enforced from Phase 4
}

// LoadThresholds reads a thresholds file.
func LoadThresholds(path string) (Thresholds, error) {
	var t Thresholds
	data, err := os.ReadFile(path)
	if err != nil {
		return t, err
	}
	if err := json.Unmarshal(data, &t); err != nil {
		return t, fmt.Errorf("%s: %w", filepath.Base(path), err)
	}
	return t, nil
}

// CaseResult is the outcome of one case. Failures lists rule names only.
type CaseResult struct {
	ID       string   `json:"id"`
	Kind     string   `json:"kind"`
	Expected string   `json:"expected,omitempty"`
	Actual   string   `json:"actual,omitempty"`
	Valid    bool     `json:"structured_output_valid"`
	Passed   bool     `json:"passed"`
	Failures []string `json:"failures,omitempty"`
}

// Metric is one aggregate value. Value is nil when no case applies.
type Metric struct {
	Value     *float64 `json:"value"`
	Numerator int      `json:"numerator"`
	Total     int      `json:"total"`
	Threshold float64  `json:"threshold"`
	Direction string   `json:"direction"` // "min" or "max"
	Passed    bool     `json:"passed"`
}

// Result is the full evaluation output written to the results file.
type Result struct {
	Model          string            `json:"model"`
	PromptVersions map[string]string `json:"prompt_versions"`
	Timestamp      time.Time         `json:"timestamp"`
	Cases          []CaseResult      `json:"cases"`
	Metrics        map[string]Metric `json:"metrics"`
	Passed         bool              `json:"passed"`
}

// Run executes every case against mc and computes metrics against th.
func Run(ctx context.Context, mc agent.ModelClient, model string, cases []Case, th Thresholds) Result {
	res := Result{
		Model:          model,
		PromptVersions: agent.EvalPromptVersions(),
		Timestamp:      time.Now().UTC(),
		Metrics:        map[string]Metric{},
	}

	var emergentTotal, emergentHit, routineTotal, routineFalse int
	var structTotal, structValid int
	var soapTotal, soapFaithful int

	for _, c := range cases {
		var cr CaseResult
		switch c.Kind {
		case KindTriage:
			cr = runTriage(ctx, mc, c)
			structTotal++
			if cr.Valid {
				structValid++
			}
			switch c.ExpectedTriage {
			case Emergent:
				emergentTotal++
				if cr.Actual == Emergent {
					emergentHit++
				}
			case Routine:
				routineTotal++
				if cr.Actual == Emergent {
					routineFalse++
				}
			}
		case KindInterviewSOAP:
			var faithful, applicable bool
			cr, faithful, applicable = runSOAP(ctx, mc, c)
			structTotal++
			if cr.Valid {
				structValid++
			}
			if applicable {
				soapTotal++
				if faithful {
					soapFaithful++
				}
			}
		}
		res.Cases = append(res.Cases, cr)
	}

	res.Metrics["emergent_recall"] = metric(emergentHit, emergentTotal, th.EmergentRecallMin, "min")
	res.Metrics["false_emergent_rate"] = metric(routineFalse, routineTotal, th.FalseEmergentRateMax, "max")
	res.Metrics["structured_output_validity"] = metric(structValid, structTotal, th.StructuredOutputValidityMin, "min")
	res.Metrics["soap_objective_fidelity"] = metric(soapFaithful, soapTotal, th.SOAPObjectiveFidelityMin, "min")

	res.Passed = true
	for _, m := range res.Metrics {
		if !m.Passed {
			res.Passed = false
		}
	}
	return res
}

// metric computes a ratio and its gate. A metric with no applicable cases
// passes vacuously and reports a nil value.
func metric(num, total int, threshold float64, dir string) Metric {
	m := Metric{Numerator: num, Total: total, Threshold: threshold, Direction: dir, Passed: true}
	if total == 0 {
		return m
	}
	v := float64(num) / float64(total)
	m.Value = &v
	if dir == "min" {
		m.Passed = v >= threshold
	} else {
		m.Passed = v <= threshold
	}
	return m
}

func runTriage(ctx context.Context, mc agent.ModelClient, c Case) CaseResult {
	cr := CaseResult{ID: c.ID, Kind: c.Kind, Expected: c.ExpectedTriage}
	out, err := agent.EvalTriage(ctx, mc, c.Turns)
	switch {
	case err != nil:
		cr.Actual = "ERROR"
		cr.Failures = append(cr.Failures, "model_error")
	default:
		cr.Actual = out.String()
		cr.Valid = out == agent.TriageEmergent || out == agent.TriageRoutine
		if !cr.Valid {
			cr.Failures = append(cr.Failures, "unparseable_triage_output")
		}
	}
	if cr.Actual != c.ExpectedTriage {
		cr.Failures = append(cr.Failures, "triage_mismatch")
	}
	cr.Passed = len(cr.Failures) == 0
	return cr
}

// runSOAP returns the case result, whether Objective was faithful, and whether
// the fidelity check applied (it cannot when no note was produced).
func runSOAP(ctx context.Context, mc agent.ModelClient, c Case) (CaseResult, bool, bool) {
	cr := CaseResult{ID: c.ID, Kind: c.Kind}
	payload, err := agent.EvalSOAP(ctx, mc, c.Turns)
	if err != nil {
		cr.Failures = append(cr.Failures, "soap_unavailable_or_invalid")
		return cr, false, false
	}
	cr.Valid = true

	sections := map[string]string{
		"SUBJECTIVE": payload.Subjective, "OBJECTIVE": payload.Objective,
		"ASSESSMENT": payload.Assessment, "PLAN": payload.Plan,
	}
	for _, s := range c.RequiredSections {
		if strings.TrimSpace(sections[s]) == "" {
			cr.Failures = append(cr.Failures, "missing_section_"+strings.ToLower(s))
		}
	}
	note := strings.ToLower(strings.Join([]string{payload.Subjective, payload.Objective, payload.Assessment, payload.Plan}, "\n"))
	for i, f := range c.MustInclude {
		if !strings.Contains(note, strings.ToLower(f)) {
			cr.Failures = append(cr.Failures, fmt.Sprintf("must_include[%d]_absent", i))
		}
	}
	for i, f := range c.MustNotInclude {
		if strings.Contains(note, strings.ToLower(f)) {
			cr.Failures = append(cr.Failures, fmt.Sprintf("must_not_include[%d]_present", i))
		}
	}
	faithful := true
	for _, term := range ObjectiveViolations(payload.Objective, c) {
		faithful = false
		cr.Failures = append(cr.Failures, "objective_unsupported_finding:"+term)
	}
	cr.Passed = len(cr.Failures) == 0
	return cr, faithful, true
}

// examFindingTerms is the built-in lexicon of findings that need a physical
// examination and so cannot come from a text interview. Matching is
// case-insensitive substring.
var examFindingTerms = []string{
	"auscultat", "rales", "crackles", "wheez", "rhonchi", "murmur",
	"bowel sounds", "palpat", "tenderness", "tender to", "rebound",
	"guarding", "percussion", "on exam", "physical exam", "lungs clear",
	"clear to auscultation", "heart sounds", "s1 s2", "jvd",
	"edema on", "pharynx erythem", "tonsillar exud", "lymphadenopathy",
	"cranial nerves", "reflexes", "oropharynx", "tympanic membrane",
}

// ObjectiveViolations returns the exam-finding terms present in objective but
// absent from the patient's own turns (the vignette), plus any terms the case
// bans outright. The check is deliberately a conservative rule, not a judge.
func ObjectiveViolations(objective string, c Case) []string {
	obj := strings.ToLower(objective)
	var vignette strings.Builder
	for _, t := range c.Turns {
		if t.Role == "user" {
			vignette.WriteString(strings.ToLower(t.Content))
			vignette.WriteString("\n")
		}
	}
	v := vignette.String()
	var out []string
	for _, term := range examFindingTerms {
		if strings.Contains(obj, term) && !strings.Contains(v, term) {
			out = append(out, term)
		}
	}
	for _, term := range c.ObjectiveMustNotContain {
		if strings.Contains(obj, strings.ToLower(term)) {
			out = append(out, strings.ToLower(term))
		}
	}
	return out
}

// WriteResult writes res to dir/<date>-<model>.json and returns the path.
func WriteResult(dir string, res Result) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	name := fmt.Sprintf("%s-%s.json", res.Timestamp.Format("2006-01-02"), sanitize(res.Model))
	path := filepath.Join(dir, name)
	data, err := json.MarshalIndent(res, "", "  ")
	if err != nil {
		return "", err
	}
	return path, os.WriteFile(path, append(data, '\n'), 0o644)
}

func sanitize(s string) string {
	b := []rune(s)
	for i, r := range b {
		ok := r == '.' || r == '_' || r == '-' ||
			(r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
		if !ok {
			b[i] = '-'
		}
	}
	if len(b) == 0 {
		return "unknown"
	}
	return string(b)
}

// Summary renders a plain-text table of the aggregate metrics.
func Summary(res Result) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "model: %s  cases: %d\n", res.Model, len(res.Cases))
	names := make([]string, 0, len(res.Metrics))
	for n := range res.Metrics {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		m := res.Metrics[n]
		val := "n/a"
		if m.Value != nil {
			val = fmt.Sprintf("%.1f%%", *m.Value*100)
		}
		op := ">="
		if m.Direction == "max" {
			op = "<="
		}
		status := "PASS"
		if !m.Passed {
			status = "FAIL"
		}
		fmt.Fprintf(&sb, "  %-28s %7s (%d/%d)  need %s %.1f%%  %s\n", n, val, m.Numerator, m.Total, op, m.Threshold*100, status)
	}
	for _, c := range res.Cases {
		if !c.Passed {
			fmt.Fprintf(&sb, "  case %s failed: %s\n", c.ID, strings.Join(c.Failures, ", "))
		}
	}
	if res.Passed {
		sb.WriteString("RESULT: PASS\n")
	} else {
		sb.WriteString("RESULT: FAIL\n")
	}
	return sb.String()
}

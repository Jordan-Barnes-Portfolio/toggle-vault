package diff

import (
	"fmt"
	"strings"

	"github.com/sergi/go-diff/diffmatchpatch"
)

// DiffResult represents the result of comparing two versions
type DiffResult struct {
	// UnifiedDiff is the traditional unified diff format
	UnifiedDiff string `json:"unified_diff"`
	// Lines contains line-by-line diff information
	Lines []DiffLine `json:"lines"`
	// Stats contains summary statistics
	Stats DiffStats `json:"stats"`
	// HasChanges indicates if there are any differences
	HasChanges bool `json:"has_changes"`
}

// DiffLine represents a single line in the diff
type DiffLine struct {
	Type       DiffLineType `json:"type"`
	OldLineNum int          `json:"old_line_num,omitempty"`
	NewLineNum int          `json:"new_line_num,omitempty"`
	Content    string       `json:"content"`
}

// DiffLineType represents the type of diff line
type DiffLineType string

const (
	DiffLineContext DiffLineType = "context"
	DiffLineAdded   DiffLineType = "added"
	DiffLineRemoved DiffLineType = "removed"
)

// DiffStats contains summary statistics about the diff
type DiffStats struct {
	LinesAdded   int `json:"lines_added"`
	LinesRemoved int `json:"lines_removed"`
	LinesChanged int `json:"lines_changed"`
}

// Compare generates a diff between two text contents
func Compare(oldContent, newContent string) *DiffResult {
	result := &DiffResult{
		Lines: []DiffLine{},
	}

	// Handle empty cases
	if oldContent == newContent {
		result.HasChanges = false
		return result
	}

	result.HasChanges = true

	dmp := diffmatchpatch.New()

	// Create line-mode diff for better readability
	oldLines, newLines, lineArray := dmp.DiffLinesToChars(oldContent, newContent)
	diffs := dmp.DiffMain(oldLines, newLines, false)
	diffs = dmp.DiffCharsToLines(diffs, lineArray)
	diffs = dmp.DiffCleanupSemantic(diffs)

	// Generate unified diff
	result.UnifiedDiff = generateUnifiedDiff(diffs, oldContent, newContent)

	// Generate line-by-line diff
	result.Lines, result.Stats = generateLineDiff(diffs)

	return result
}

// generateUnifiedDiff creates a unified diff format string
func generateUnifiedDiff(diffs []diffmatchpatch.Diff, oldContent, newContent string) string {
	var sb strings.Builder

	sb.WriteString("--- old\n")
	sb.WriteString("+++ new\n")

	oldLineNum := 1
	newLineNum := 1

	for _, diff := range diffs {
		lines := strings.Split(diff.Text, "\n")

		// Remove empty last element if the text ends with newline
		if len(lines) > 0 && lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}

		for _, line := range lines {
			switch diff.Type {
			case diffmatchpatch.DiffEqual:
				sb.WriteString(fmt.Sprintf(" %s\n", line))
				oldLineNum++
				newLineNum++
			case diffmatchpatch.DiffDelete:
				sb.WriteString(fmt.Sprintf("-%s\n", line))
				oldLineNum++
			case diffmatchpatch.DiffInsert:
				sb.WriteString(fmt.Sprintf("+%s\n", line))
				newLineNum++
			}
		}
	}

	return sb.String()
}

// generateLineDiff creates a structured line-by-line diff
func generateLineDiff(diffs []diffmatchpatch.Diff) ([]DiffLine, DiffStats) {
	var lines []DiffLine
	var stats DiffStats

	oldLineNum := 1
	newLineNum := 1

	for _, diff := range diffs {
		diffLines := strings.Split(diff.Text, "\n")

		// Remove empty last element if the text ends with newline
		if len(diffLines) > 0 && diffLines[len(diffLines)-1] == "" {
			diffLines = diffLines[:len(diffLines)-1]
		}

		for _, content := range diffLines {
			switch diff.Type {
			case diffmatchpatch.DiffEqual:
				lines = append(lines, DiffLine{
					Type:       DiffLineContext,
					OldLineNum: oldLineNum,
					NewLineNum: newLineNum,
					Content:    content,
				})
				oldLineNum++
				newLineNum++

			case diffmatchpatch.DiffDelete:
				lines = append(lines, DiffLine{
					Type:       DiffLineRemoved,
					OldLineNum: oldLineNum,
					Content:    content,
				})
				oldLineNum++
				stats.LinesRemoved++

			case diffmatchpatch.DiffInsert:
				lines = append(lines, DiffLine{
					Type:       DiffLineAdded,
					NewLineNum: newLineNum,
					Content:    content,
				})
				newLineNum++
				stats.LinesAdded++
			}
		}
	}

	// Estimate changed lines (where a removal is followed by an addition)
	stats.LinesChanged = min(stats.LinesAdded, stats.LinesRemoved)

	return lines, stats
}

// CompareVersions compares two version contents and returns a structured diff
func CompareVersions(oldContent, newContent, oldLabel, newLabel string) *DiffResult {
	result := Compare(oldContent, newContent)

	// Update the unified diff header with custom labels
	if result.HasChanges {
		result.UnifiedDiff = strings.Replace(result.UnifiedDiff, "--- old", "--- "+oldLabel, 1)
		result.UnifiedDiff = strings.Replace(result.UnifiedDiff, "+++ new", "+++ "+newLabel, 1)
	}

	return result
}

// min returns the smaller of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
